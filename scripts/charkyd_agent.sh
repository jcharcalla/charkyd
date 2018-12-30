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
	logger -i "charkyd_agent: Service :${SERVICENAME} attempting restart."
        systemctl restart ${SERVICENAME}.service
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:restarted,pid:na,nodeid:${HOSTID},epoch:${EPOCH}
}

start_service()
{
	logger -i "charkyd_agent: Service :${SERVICENAME} attempting start."
        systemctl start ${SERVICENAME}.service
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:started,pid:na,nodeid:${HOSTID},epoch:${EPOCH}
        }

stop_service()
{
	logger -i "charkyd_agent: Service :${SERVICENAME} attempting stop."
        systemctl stop ${SERVICENAME}.service
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:stopped,pid:na,nodeid:${HOSTID},epoch:${EPOCH}
        }

deploy_service()
{
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
        ${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} servicename:${SERVICE_NAME_ORIG},state:started
        ${ETCDCTL_BIN} del ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG}

else
        ${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} ${line},servicestatus:failed
        logger -i "charkyd_agent: WARNING Scheduled service: ${SERVICE_NAME_ORIG} failed deployment!"

fi
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
		logger -i "charkyd_agent: Checking state of scheduled service:${SERVICENAME}."
                # I should have an if here, if scheduler, or if monitor do it a little differnt
                # This should include starting a lease for the status of the service.
                # a seperate non node lease.
                case ${DESIERED_SERVICE_STATE} in
                start|START|started|STARTED|running)
                        if [ "$(systemctl is-active ${SERVICENAME})" != 'active' ];
                        then
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
                        logger -i "charkyd_agent: WARNING Scheduled service: \"${SERVICENAME}\", unknown service state: \"${DESIRED_SERVICE_STATE}\""
                ;;
                # A migrate using CRIU option would be cool.

                # after changes we should resubmit basics on core and mem count. Although, this is somewhat outside the scpoe
                # and should be done by the application per say or nagios, icinga, or tick stack metrics. Lets not
                # re-invent the wheel.
                esac
}

launch_reaper_task()
{
	while /bin/true
	do
	# This shoiuld launch a simple sub proccess or script that
	# checks that all scheduled tasks for thjis node are in the
	# desired state every x seconds.
        # This should make use of the service_state_case
		logger -i "charkyd_agent: ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e \"servicename:\" -e \"state:\""
	        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e "servicename:" -e "state:" | while read -r line; do
			logger -i "charkyd_agent: Verifying state of scheduled services via reaper task."
                	DESIRED_SERVICE_STATE=$(echo ${line} | sed 's/.*state://' | cut -d "," -f1)
                	SERVICENAME=$(echo ${line} | sed 's/.*servicename://' | cut -d "," -f1)

                	# Run desired action for service
          	      	service_state_case
       		done
		sleep ${REAPER_SLEEP}
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

# Check if a scheduler is currently running and if not start one on a randome node.

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
	DESIRED_SERVICE_STATE=$(echo ${line} | sed 's/.*state://' | cut -d "," -f1)
	SERVICENAME=$(echo ${line} | sed 's/.*servicename://' | cut -d "," -f1)

	# Run desired action for service
	service_state_case
  fi
done< <(exec tail -fn0 ${WATCH_LOG})
# Alternativly we could skip writing to disk and just exec the etcd watch 
#done< <(exec ${ETCDCTL_BIN} watch --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID})

exit 0
