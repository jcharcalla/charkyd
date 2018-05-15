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

CONFIG=/etc/charkyd.conf
MEM_CONFIG=/dev/shm/charkyd.mem.conf
NODE_LEASE_KEEPALIVE_PID=/var/run/charkyd_agent_node.pid
NODE_TASK_WATCH_PID=/var/run/charkyd_agent_taskwatch.pid
WATCH_LOG=/var/log/charkyd_watch.log

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


#
# Register node and report its availibility by creating a lease and
# tyring a status key to it.
#

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
        echo $! > ${NODE_TASK_WATCH_PID}
}


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
tail -fn0 ${WATCH_LOG} | while read wline ;
do
  if echo ${wline} | grep -q "${HOSTID}"
  then
	# we can probably just pull this from the $wline var above to simplify this and reduce queries.
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATE}/${REGION}/${RACK}/${HOSTID} | grep -e "servicename:" -e "state:" | while read -r line
	do 
		DESIRED_SERVICE_STATE=$(echo ${line} | sed 's/.*state://' | cut -d "," -f1)
		SERVICENAME=$(echo ${line} | sed 's/.*servicename://' | cut -d "," -f1)
   		case ${DESIERED_SERVICE_STATE} in
	   	started|STARTED|running)
			if [ "$(systemctl is-active ${SERVICENAME})" != 'active' ];
			then 
				restart_service 
			fi
	  	;;
  	  	stopped|STOPPED|disabled)
			stop_service
		  ;;
  		  restart|RESTART|restarted|RESTARTED)
			restart_service
		  ;;
       		   scheduled|SCHEDULED)
	  		logger -i "charkyd_agent: Scheduled service:${SERVICENAME} not yet deployed."
		  ;;
  		  *)
	  		logger -i "charkyd_agent: WARNING Scheduled service: ${SERVICENAME} unknown service state: ${DESIRED_SERVICE_STATE}!"
		  ;;
		esac
	done
  fi
done

exit 0
