#
#
# charkyd_agent.sh
#
# Reports node and service status to etcd V3 and manages services.
#
# Author: Jason Charcalla
# Copyright 2018
#

# Prereqs:
# openssl for hash gen
# etcdctl https://github.com/coreos/etcd/releases

# Changelog:
# v.1 initial version
#

# Set selinux to permisive now, this is due to systemd-notify
# systemd-notify --ready --status="charkyd now watching for services to run"

# Ideas
# I need to add the concept of service groups and tie TTL processe to them.
# I would also need to kill the status key if for some reason the service 
# was not running locally
#
# There should be a concept of schedule ordering, however that sounds like
# it shoud be done by whatever submits the services. aka a startup
# order for resuming after power outages. essentially we need a feild in the db
# and a snopshot of it prior to shutdown, so that it can be resubmitted in the
# correct order on power up.

##
## There should be a local state cache <file>, maybe just the log, 
## which could be used if we loose etcd connectivity. maybe this is what happebs during maintinance
## actually, if you need to take down etcd. then stop the service 1st.
## if we lose connection to the db, do we stay up or kill all?
##

# If there is no config file create one and create a host id
CONFIG=/etc/charkyd.conf

if [ ! -f ${CONFIG} ]
then
        HOSTID=$(openssl rand -hex ${UUID_LENGTH})
        echo "HOSTID=${HOSTID}" > ${CONFIG}
else
        #. ${CONFIG}
        source ${CONFIG}
        # Check if we sourced the HOSTID var from the config, if not this is a new host so make a new one
        if [ -z ${HOSTID} ]
        then
                HOSTID=$(openssl rand -hex ${UUID_LENGTH})
                echo "HOSTID=${HOSTID}" >> ${CONFIG}
        fi
fi

MEM_CONFIG=/dev/shm/charkyd.mem.conf
NODE_LEASE_KEEPALIVE_PID=/var/run/charkyd_agent_node.pid
NODE_TASK_WATCH_PID=/var/run/charkyd_agent_taskwatch.pid
WATCH_LOG=/var/log/charkyd_agentwatch.log

# config options (these should be stored as factors on the node)
# putting these here for now, they should be in the config file
export ETCDCTL_API=3
# Idea: allow for multiple raft db backends via wrapper script
# make commands generic here and if the db doesnt support something
# like watch, drop back to reaper mode only.
ETCDCTL_BIN=/usr/local/bin/etcdctl
# these should be differnt, more like
#//charkyd/${API_VERSION}/${NAMESPACE}/${REGION}/${RACK}/${NODE}/status/
#//charkyd/${API_VERSION}/${NAMESPACE}/${REGION}/${RACK}/${NODE}/${SERVICE}/status/
#//charkyd/${API_VERSION}/${NAMESPACE}/${REGION}/${RACK}/${NODE}/${SERVICE}/state/
PREFIX_SCHEDULED=/charkyd/${API_VERSION}/${NAMESPACE}/services/scheduled
PREFIX_STATE=/charkyd/${API_VERSION}/${NAMESPACE}/services/state
#PREFIX_PAUSED=/charkyd/${API_VERSION}/${NAMESPACE}/services/paused
PREFIX_MONITOR=/charkyd/${API_VERSION}/${NAMESPACE}/services/monitor
PREFIX_STATUS=/charkyd/${API_VERSION}/${NAMESPACE}/services/status
#PREFIX_TERMINATED=/charkyd/${API_VERSION}/${NAMESPACE}/services/terminated
#PREFIX_ERASED=/charkyd/${API_VERSION}/${NAMESPACE}/services/erased
PREFIX_NODES=/charkyd/${API_VERSION}/${NAMESPACE}/nodes
MONITOR_MIN=3
MONITOR_ELECTS=1
SCHEDULER_STATE_CHECK=5
MAX_SERVICE_STATE_FAILURES=6


# Dynamic variables.
NUMPROC=$(nproc --all)
TOTMEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTMEM=$((TOTMEM/102400))
FQDN=`nslookup $(hostname -f) | grep "Name:" | cut -d":" -f2 | xargs`
IPV4=`nslookup $(hostname -f) | grep "Name:" -A1 | tail -n1 | cut -d":" -f2 | xargs`
EPOCH=$(date +%s)

#
# Load or generate config files
#

# Do it in a way that may be safer than just sourcing the file
# Coming back to this later 12-25-18
load_config()
{
	grep -e HOSTID -e ETCD_ENDPOINTS -e REGION -e RACK -e NAMESPACE ${CHARKYD_CONF}
	while read config_line
       	do
	    ????
	done
}



#
# Register node and report its availibility by creating a lease and
# tyring a status key to it.
#

# With this new method I need a way for the node to re-report itself if it;s entry in the
# db gets deleted. aka a sub proccess that every minut or so rewrites its db entry 
# as a form of long term heart beat.
create_node_lease()
{
	NODE_LEASE=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease grant ${NODE_LEASE_TTL} | cut -d " " -f 2 )
	# echo "NODE_LEASE=${NODE_LEASE}" >> ${MEM_CONFIG}
	# Register the node and assign the new lease as it most likely does not exist.
	# ADD A CHECK HERE ENSURING THE NODE IS NOT ALREADY IN THE DB
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_NODES}/${REGION}/${RACK}/${HOSTID} nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,numproc:${NUMPROC},totmem:${TOTMEM},epoch:${EPOCH},arch:x86_64
	# Background a keepalive proccess for the node, so that if it stops the node key are removed
	KEEPA_CMD="${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease keep-alive ${NODE_LEASE}"
	nohup ${KEEPA_CMD} &
	echo $! > ${NODE_LEASE_KEEPALIVE_PID}
}

# Check for the presence of a node lease ID
if [ ! -f ${NODE_LEASE_KEEPALIVE_PID} ]
then
	create_node_lease
else
	if [ ! `kill -0 $(cat ${NODE_LEASE_KEEPALIVE_PID})` ]
	then
		# create a new node lease because this one must be stale
		create_node_lease
	fi
fi

#
# This could be a method to populate all a nodes services into the DB
#
# systemd-analyze dump | awk '/-> Unit /{u=$3} /Unit Load State: /{l=$4} /Unit Active State: /{s=$4} /^->/{print u" "l": "s}'

#
# I could add a mode where we start and stop LXD or SWARM services directly, as a type of over cluster...
#


# check if something should be running or what state it should be in
restart_service()
{
	logger -i "charkyd_agent: Service:\"${SERVICENAME}\", attempting restart."
	restart_service_state=1
	# if this is a schduler or monitor dont put a lease on the key
	# those services put there own lease on the status key
	put_lease="--lease=${NODE_LEASE}"
	if [ ${SCHEDULER_SERVICE_NAME} == ${SERVICENAME} ]
	then
		put_lease=""
	elif [ ${MONITOR_SERVICE_NAME} == ${SERVICENAME} ]
	then
		put_lease=""
	fi

        systemctl restart ${SERVICENAME}.service || restart_service_state=0

	if [ ${restart_service_state} -eq 0 ]
	then
		service_state_failures=$(( ${service_state_failures} + 1 ))
		logger -i "charkyd_agent: ERROR: Service:\"${SERVICENAME}\", failed restart."
		${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${put_lease} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:failed_restart,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:${service_state_failures}
	else
		logger -i "charkyd_agent: Service:\"${SERVICENAME}\", restarted."
		${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${put_lease} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:restarted,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:0
	fi
		
}

start_service()
{
	logger -i "charkyd_agent: Service:\"${SERVICENAME}\", attempting start."
	start_service_state=1
        # if this is a schduler or monitor dont put a lease on the key
        # those services put there own lease on the status key
        put_lease="--lease=${NODE_LEASE}"
        if [ ${SCHEDULER_SERVICE_NAME} == ${SERVICENAME} ]
        then    
                put_lease=""
        elif [ ${MONITOR_SERVICE_NAME} == ${SERVICENAME} ]
        then    
                put_lease=""
        fi

        systemctl start ${SERVICENAME}.service || start_service_state=0
	if [ ${start_service_state} -eq 0 ]
	then
		logger -i "charkyd_agent: ERROR: Service:\"${SERVICENAME}\", failed start."
		service_state_failures=$(( ${service_state_failures} + 1 ))
        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${put_lease} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:failed_start,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:${service_state_failures}
	else
		logger -i "charkyd_agent: Service:\"${SERVICENAME}\", started."
        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${put_lease} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:started,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:0
	fi
        }

stop_service()
{
	logger -i "charkyd_agent: Service:\"${SERVICENAME}\", attempting stop."
	stop_service_state=1
        systemctl stop ${SERVICENAME}.service || stop_service_state=0
	if [ ${start_service_state} -eq 0 ]
	then
	        logger -i "charkyd_agent: ERROR: Service:\"${SERVICENAME}\", failed stop."
	        service_state_failures=$(( ${service_state_failures} + 1 ))
        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:failed_stop,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:${service_state_failures}
	else
	        logger -i "charkyd_agent: ERROR: Service:\"${SERVICENAME}\", stopped."
        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:stopped,pid:na,nodeid:${HOSTID},epoch:${EPOCH},failures:0
	fi
        }

deploy_service()
{
SERVICE_NAME_ORIG=${SERVICENAME}
line=${wline}
# Run deployment shell `git clone ansible && ansible-playbook ...`
logger -i "charkyd_agent: Deploying scheduled service: ${SERVICE_NAME_ORIG}"
echo "NODEID=${NODEID}" > /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_IPV4=${NODE_IPV4}" >> /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_IPV6=${NODE_IPV6}" >> /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_FQDN=${NODE_FQDN}" >> /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo ${DEPLOY_CMD} >> /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
chmod +x /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
/usr/bin/sh /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh

# On success of installing the service, submit the job to node or nodes (maybe
# have monitoring service start the nodes like the previous version)

# once deployment has been sucseccful delete the entry and add it to a 
# /deployed/region/rack/nodeid location so that we can remove them if needed
# or at least know what was deployed where.
if [ $? -ne 0 ]
then
        logger -i "charkyd_agent: starting scheduled service: ${SERVICE_NAME_ORIG}"
        #${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME_ORIG} servicename:${SERVICE_NAME_ORIG},state:started
	${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME_ORIG} servicename:${SERVICE_NAME_ORIG},state:started,nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,epoch:${EPOCH}
        ${ETCDCTL_BIN} del ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG}

else
        # get the proper line from the scheduled queue here
	SCHEDLINE=$(${ETCDCTL_BIN} get --prefix ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} | grep "servicename:")
        SCHEDNEWLINE=$(echo ${SCHEDLINE} | sed "s/servicestatus:agent_deploy/servicestatus:failed/g")
	echo "charkys_agent: debug: ${ETCDCTL_BIN} get --prefix ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} | grep \"servicename:\""
	echo "charkys_agent: debug: SCHEDNEWLINE: ${SCHEDNEWLINE}"
        NEWLINE=$(echo ${line} | sed "s/state:deploy/state:deploy_failed/g")
	echo "charkys_agent: debug: NEWLINE: ${NEWLINE}"
        ${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} "${SCHEDNEWLINE}"
        # I think this should be putting to the scheduled queue, it would need to update this in the 
        # case of a remote install
        ${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME_ORIG} "${NEWLINE}"
#        ${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} ${line},servicestatus:failed
	#${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME_ORIG} servicename:${SERVICE_NAME_ORIG},state:deploy_failed
        logger -i "charkyd_agent: WARNING Scheduled service: ${SERVICE_NAME_ORIG} failed deployment!"

fi
}

start_scheduler_service()
{
        # should this advertise its running to its own agent service for restart?
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}/${SCHEDULER_SERVICE_NAME} servicename:${SCHEDULER_SERVICE_NAME},unit_file:${SCHEDULER_SERVICE_NAME}.service,replicas:1,nodeid:${HOSTID},epoch:${EPOCH},state:started,failures:0;
}

#
# This is where we check and update the status of the local service
#

# start a watcher if its not already running NODE_TASK_WATCH_PID
watch_node_tasks()
{
        #TASKW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID} | while read wline; do echo ${wline} | grep -q "${HOSTID}" && $0 & done"
        TASKW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID}"
	echo ${TASKW_CMD}
        nohup ${TASKW_CMD} > ${WATCH_LOG} 2>&1&
	# to not log the puts and other info I could probably do this
        #nohup ${TASKW_CMD} | grep servicename >> ${WATCH_LOG} 2>&1&
	# This didnt work, I even tried it on the TASKW_CMD
	logger -i "charkyd_agent: Node watch task started PID:${NODE_TASK_WATCH_PID}."
        echo $! > ${NODE_TASK_WATCH_PID}
}

service_state_case()
{
                # could add a service type here to allow restarting of LXD or SWARM containers
                # Or that could be a seperate script
		logger -i "charkyd_agent: Checking that desired state of scheduled service:\"${SERVICENAME}\", is \"${DESIRED_SERVICE_STATE}\"."

		# Check if the service has failed start to amny times to try again.
		service_state_failures=0
		while read state_line
		do
			service_state_failures=$(echo ${state_line} | sed 's/.*failures://' | cut -d "," -f1)
		done< <(exec ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} | grep "service:")

		if [ ${service_state_failures} -ge ${MAX_SERVICE_STATE_FAILURES} ]
		then
			logger -i "charkyd_agent: ERROR: Skipping service:\"${SERVICENAME}\", too many failures!"
			# return from shell function
			return
		fi
			
                # I should have an if here, if scheduler, or if monitor do it a little differnt
                # This should include starting a lease for the status of the service.
                # a seperate non node lease.

		# Not sure why i have to do this, might be something with spawning the sub proccess.
		CASE_SERVICE_STATE=${DESIRED_SERVICE_STATE}
                case ${CASE_SERVICE_STATE} in
                	started|START|start|STARTED|running)
                        	if [ "$(systemctl is-active ${SERVICENAME})" != 'active' ];
                        	then
					logger -i "charkyd_agent: Attempting \"${DESIRED_SERVICE_STATE}\" of service:\"${SERVICENAME}\"."
                                	restart_service
                        	fi
                		;;
                	stop|STOP|stopped|STOPPED|disabled)
                        	stop_service
                		;;
                	restart|RESTART|restarted|RESTARTED)
                        	restart_service
                		;;
                	pause|PAUSE|freeze|FREEZE)
                        	echo "Nothing to do now"
                		;;
                	resume|RESUME|thaw|THAW)
                        	echo "Nothing to do now"
                		;;
                	deploy|DEPLOY)
                        	echo "Deploying service"
                        	deploy_service
				;;
			deploy_failed)
				logger -i "charkyd_agent: ERROR: Skipping service:\"${SERVICENAME}\", deployment failed!"
                		;;
                	destroy|DESTROY|stonith|STONITH)
                        # if the service exists, make sure its stopped.
                		;;
                	maintinance|MAINTINANCE|maint|MAINT)
                        # In this mode we should just log the current state to allow the user to control
                		;;
                	scheduled|SCHEDULED)
                        	logger -i "charkyd_agent: Scheduled service:\"${SERVICENAME}\", not yet deployed."
                		;;
                	*)
                        	logger -i "charkyd_agent: WARNING Scheduled service:\"${SERVICENAME}\", unknown service state:\"${DESIRED_SERVICE_STATE}\""
                		;;
                # A migrate using CRIU option would be cool

                # after changes we should resubmit basics on core and mem count. Although, this is somewhat outside the scpoe
                # and should be done by the application per say or nagios, icinga, or tick stack metrics. Lets not
                # re-invent the wheel.
                esac
}

launch_reaper_task()
{
	counter=0
	while /bin/true
	do
	# This shoiuld launch a simple sub proccess or script that
	# checks that all scheduled tasks for thjis node are in the
	# desired state every x seconds.
        # This should make use of the service_state_case
	#	logger -i "charkyd_agent: ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e \"servicename:\" -e \"state:\""
		logger -i "charkyd_agent: Verifying state of scheduled services via reaper task."
	        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e "servicename:" -e "state:" | while read -r line; do
                	DESIRED_SERVICE_STATE=$(echo ${line} | sed 's/.*state://' | cut -d "," -f1)
                	SERVICENAME=$(echo ${line} | sed 's/.*servicename://' | cut -d "," -f1)
                	service_state_case

       		done
                # Check if a scheduler is currently running and if not start one on this node.
                if [ ${counter} -eq 1 ]
                then
                       active_scheduler_count=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep "servicename:${SCHEDULER_SERVICE_NAME}" | grep "state:started"| wc -l)
                       if [ ${active_scheduler_count} -ge 1 ]
                       then
                              logger -i "charkyd_agent: ${active_scheduler_count} scheduler services reported via reaper task."
                       else
                              logger -i "charkyd_agent: WARN: No scheduler services reported via reaper task! Starting..."
                              start_scheduler_service
                       fi
                elif [ ${counter} -eq ${SCHEDULER_STATE_CHECK} ]
                then
                       counter=0
                fi

		sleep ${REAPER_SLEEP}
                counter=$(( ${counter} + 1 ))
	done
}

echo "charkyd_agent: ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e \"servicename:\" -e \"state:\""
logger -i "charkyd_agent: ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e \"servicename:\" -e \"state:\""

# Launch the reaper task as a sub proccess (this may need to be it's own script)
launch_reaper_task &

# If it is already running maybe it triggered this so run through and start things. 
if [ ! -f ${NODE_TASK_WATCH_PID} ]
then
        watch_node_tasks
else
        if [ ! `kill -0 $(cat ${NODE_TASK_WATCH_PID})` ]
        then
        	watch_node_tasks
        fi
fi

# Notify systemd that we are ready
systemd-notify --ready --status="charkyd now watching for services to run"

# This is a hack for no exec-watch in etcd3. lets watch the log file from the 
# backgrounded proccess to trigger on.
# https://github.com/coreos/etcd/pull/8919

# I need a way to ensure the watch pid is still running and break this loop
# if soemthing fails. I should also check the TTL keepalive, maybe systemd can do that

#
# I may want to have this be yet another script that is spawned by this one
# This would also allow me a reaper type of script that simply compared states
# in a slower interval in case something was missed.
#
# Maybe a better idea https://stackoverflow.com/questions/30787575/using-tail-f-on-a-log-file-with-grep-in-bash-script
#
# This works # while read line; do echo "Detected new service ${line}"; done< <(exec tail -fn0 /var/log/charkyd_watch.log)
#
# Note: you get 3 lines
# Detected new service PUT
# Detected new service /charkyd/v1/cluster1/services/state/region1/rack1/7bf138d47b875118324bc9a6/test6
# Detected new service servicename:test6
#
# I may be able to grep these out when I write the log, but I may want the info, or just grep out what I
# need in the middle of the while loop
#
while read wline ;
do
  if echo ${wline} | grep -q "servicename"
  then
	# we can probably just pull this from the $wline var above to simplify this and reduce queries.
	# although, with this method we could sweep the entire list for this host in case we missed
	# something.
	DESIRED_SERVICE_STATE=$(echo ${wline} | sed 's/.*state://' | cut -d "," -f1)
	SERVICENAME=$(echo ${wline} | sed 's/.*servicename://' | cut -d "," -f1)
	SERVICE_NAME_ORIG=${SERVICENAME}
	
	logger -i "charkyd_agent: Service state change detected in ${WATCH_LOG}."

	# Run desired action for service
	service_state_case
  fi
done< <(exec tail -fn0 ${WATCH_LOG})
# Alternativly we could skip writing to disk and just exec the etcd watch 
#done< <(exec ${ETCDCTL_BIN} watch --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID})

exit 0
