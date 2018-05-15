#
# This is meant to be containerized
#
# The original versionm of this ran locally, that would seem
# to me as a security risk of some sort (if this is pushing
# ansible to other hosts), but in high demand
# workloads could be beneficial to run locally. this should
# support both methods, and could be tweaked to search only
# for jobs scheduled on the local node and run ansible against
# local host, but then every node would be pulling from git.
#

#
#
# charkyd_scheduler.sh
#
# waits for new job, deploys them, and starts them
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


CONFIG=/etc/charkyd.conf
SCHEDULE_WATCH_PID=/var/run/charkyd_agent_taskwatch.pid
WATCH_LOG=/var/log/charkyd_schedwatch.log
ELECTION_SLEEP=5

# config options (these should be stored as factors on the node)
# putting these here for now, they should be in the config file
ETCD_ENDPOINTS="192.168.79.61:2379,192.168.79.62:2379,192.168.79.63:2379"
export ETCDCTL_API=3
ETCDCTL_BIN=/usr/local/bin/etcdctl
REGION=region1
RACK=rack1
UUID_LENGTH=12
API_VERSION=v1
NAMESPACE=cluster1
NODE_LEASE_TTL=30
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

# If there is no config file create one and create a host id
if [ ! -f ${CONFIG} ]
then
        HOSTID=$(openssl rand -hex ${UUID_LENGTH})
        echo "HOSTID=${HOSTID}" > ${CONFIG}
else
        source ${CONFIG}
        # Check if we sourced the HOSTID var from the config, if not this is a new host so make a new one
        if [ -z ${HOSTID} ]
        then
                HOSTID=$(openssl rand -hex ${UUID_LENGTH})
                echo "HOSTID=${HOSTID}" >> ${CONFIG}
        fi
fi

##
## Functions
##

# add a status for this service with its own ttl
# Start 3 monitors for this service, unless this service is running everywhere...
#
# Watch for new jobs

watch_scheduled()
{
        SCHEDW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_SCHEDULED}/ | grep "schedulernode:none""
        echo ${SCHEDW_CMD}
        nohup ${SCHEDW_CMD} > ${SCHEDULE_WATCH_LOG} 2>&1&
        echo $! > ${SCHEDULE_WATCH_PID}
}

# Select hosts to be monitors
elect_monitor()
{
        for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | sort -R | head -n${MONITOR_ELECTS} | cut -d "," -f1 | cut -d ":" -f 2);
	        do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_MONITOR}/${REGION}/${RACK}/${i}/${SERVICENAME} servicename:${SERVICENAME},unit_file:${UNIT_FILE},replicas:${REPLICAS},nodeid:${HOSTID},epoch:${EPOCH};
        done
}

elect_node()
{
	${ETCDCTL_BIN} get --prefix ${NODE_SEARCH_PREFIX} | grep nodeid | sort -R | head -n 1
	NODE_IPV4=$(echo ${line} | sed 's/.*ipv4://' | cut -d "," -f1)
	NODE_IPV6=$(echo ${line} | sed 's/.*ipv6://' | cut -d "," -f1)
	NODE_FQDN=$(echo ${line} | sed 's/.*fqdn://' | cut -d "," -f1)
	NODEID=$(echo ${line} | sed 's/.*nodeid://' | cut -d "," -f1)
}

deploy_service()
{
# Run deployment shell `git clone ansible && ansible-playbook ...`
logger -i "charkyd_scheduler: Deploying scheduled service: ${SERVICE_NAME_ORIG}"
echo "NODEID=${NODEID}" > /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_IPV4=${NODE_IPV4}" > /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_IPV6=${NODE_IPV6}" > /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
echo "NODE_FQDN=${NODE_FQDN}" > /tmp/${NODEID}.${SERVICE_NAME_ORIG}.deploy.sh
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
        logger -i "charkyd_scheduler: starting scheduled service: ${SERVICE_NAME_ORIG}"
        ${ETCDCTL_BIN} put ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} servicename:${SERVICE_NAME_ORIG},state:started
        ${ETCDCTL_BIN} del ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG}
                       
else
        ${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} ${wline},servicestatus:failed
	logger -i "charkyd_scheduler: WARNING Scheduled service: ${SERVICE_NAME_ORIG} failed deployment!"

fi
}


# If it is already running maybe it triggered this so run through and start things. 
if [ ! -f ${SCHEDULE_WATCH_PID} ]
then
        watch_scheduled
else
        if [ ! `kill -0 $(cat ${SCHEDULE_WATCH_PID})` ]
        then
                watch_scheduled
        fi
fi

# Notify systemd that we are ready
systemd-notify --ready --status="charkyd now watching for services to schedule"

# Go into a loop...
# figure out a way to break out of this if the pid stops
tail -fn0 ${SCHEDULE_WATCH_LOG} | while read wline ;
do
	# take the job, aka update key. then wait and query the key again to make 
	# sure we have it claimed add something like "scheduler:thisnode"
	# Update status, maybe rename via delete
	NEWLINE=$(echo ${wline} | sed "s/schedulernode:none/schedulernode:${HOSTID}/g")
	${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/ ${NEWLINE};

	# Wait and see if another node beat us to the job
	sleep ${ELECTION_SLEEP}

	# check if any other schduler has claimed it after us
	VERIFY_SCHEDW="${ETCDCTL_BIN} watch --prefix ${PREFIX_SCHEDULED}/ | grep "scheduler:${HOSTID}""
	if [ ${NEWLINE} = ${VERIFY_SCHEDW} ]
	then
		# Set this in case we decide not to deploy it
		SKIP_SERVICE=0
		# Parse the entry. these should be there, make sure whatever client I
		# come up with requires these or creates them
		#
		# In the previous version I added a hash to the service name here.
		# Still a good idea, but lets rely on the client to do that.
		SERVICE_NAME_ORIG=$(echo ${line} | sed 's/.*servicename://' | cut -d "," -f1)
		DEPLOY_CMD=$(echo ${line} | sed 's/.*deploycmd://' | cut -d "," -f1)
		REPLICAS=$(echo ${line} | sed 's/.*replicas://' | cut -d "," -f1)
		KEEPALIVE=$(echo ${line} | sed 's/.*keepalive://' | cut -d "," -f1)
		SERVICE_NODE=$(echo ${line} | sed 's/.*servicenode://' | cut -d "," -f1)
		SERVICE_REGION=$(echo ${line} | sed 's/.*serviceregion://' | cut -d "," -f1)
		SERVICE_RACK=$(echo ${line} | sed 's/.*servicerack://' | cut -d "," -f1)
		SCHEDULER_NODE=$(echo ${line} | sed 's/.*schedulernode://' | cut -d "," -f1)
		# I should have a delimited list of possible or prefered nodes to run on

		# on new job select nodes from correct rack, reagion, <alt>, node specific.
		# choose node to run on
		if [ ${SERVICE_NODE} != "none" ]
		then
			NODE_SEARCH_PREFIX=${PREFIX_NODES}/${SERVICE_REGION}/${SERVICE_RACK}/${SERVICE_NODE}		
		else if [ ${SERVICE_RACK} != "none" ]
			NODE_SEARCH_PREFIX=${PREFIX_NODES}/${SERVICE_REGION}/${SERVICE_RACK}
		# Should we be deploying things out of our region?
		#else if [ ${SERVICE_REGION} != "none" ]
		#	NODE_SEARCH_PREFIX=${PREFIX_NODES}/${SERVICE_REGION}/
		else if [ ${SERVICE_REGION} = ${REGION} ]
			NODE_SEARCH_PREFIX=${PREFIX_NODES}/${SERVICE_REGION}/
		else
			SKIP_SERVICE=1
		fi

		if [ ${SKIP_SERVICE} -ne 0 ]
		then
			if [ ${REPLICAS} -eq 1 ]
			then
				if [ ${SERVICE_NODE} = "none" ]
					elect_node
					deploy_service
				else
					NODEID=${SERVICE_NODE}
					${ETCDCTL_BIN} get --prefix ${NODE_SEARCH_PREFIX} | grep nodeid
				        NODE_IPV4=$(echo ${line} | sed 's/.*ipv4://' | cut -d "," -f1)
				        NODE_IPV6=$(echo ${line} | sed 's/.*ipv6://' | cut -d "," -f1)
				        NODE_FQDN=$(echo ${line} | sed 's/.*fqdn://' | cut -d "," -f1)
				        NODEID=$(echo ${line} | sed 's/.*nodeid://' | cut -d "," -f1)
					deploy_service
				fi

			else if [ ${REPLICAS} -gt 1 ]
			then
				PREV_NODE=none
				#elect and deploy in a loop
				while [ $i -le ${REPLICAS} ]
				do
			        	elect_node
					# This needs fixed to not deploy on the same node, not just the last used
					if [ ${PREV_NODE} != ${NODEID} ]
					then
			        		deploy_service
						PREV_NODE=${NODEID}
						i=$(( $i + 1 ))
					fi
				done
			else
					${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} ${wline},servicestatus:failed
                        		logger -i "charkyd_scheduler: WARNING Invalid replica count for service: ${SERVICE_NAME_ORIG} Deployment Failed!"
					SKIP_SERVICE=1
			fi
			# If monitoring was requested start them now (need method for custome monitor,
			# also, monitors should monitor each other and submit a new job if needed)
			# This should be a function in the above if statements so it can be repeated
			# Need to work on how I do that, aka itterate through them

		else
			# This service is outside of my region, not sure why this would ever be a problem
			# in a real world scenario. Give it back to the scheduler
			${ETCDCTL_BIN} put ${PREFIX_SCHEDULED}/${SERVICE_NAME_ORIG} ${wline}
                        logger -i "charkyd_scheduler: WARNING Scheduled service: ${SERVICE_NAME_ORIG} unknown region!"
		fi


	fi

done


exit 0
