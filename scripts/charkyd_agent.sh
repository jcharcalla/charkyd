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

CONFIG=/etc/charkyd.conf
MEM_CONFIG=/dev/shm/charkyd.mem.conf

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
#PREFIX_RUNNING=/charkyd/${API_VERSION}/${NAMESPACE}/services/running
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
	echo "NODE_LEASE=${NODE_LEASE}" >> ${MEM_CONFIG}
	# Register the node and assign the new lease as it most likely does not exist.
	# ADD A CHECK HERE ENSURING THE NODE IS NOT ALREADY IN THE DB
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${NODE_LEASE} ${PREFIX_NODES}/${REGION}/${RACK}/${HOSTID} nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,numproc:${NUMPROC},totmem:${TOTMEM},epoch:${EPOCH},arch:x86_64
}

# Check for the presence of a node lease ID
if [ ! -f ${MEM_CONFIG} ]
then
	create_node_lease
else
        source ${MEM_CONFIG}
        # Check if we sourced the NODE_LEASE var from the config, if not this is a new host so make a new one
        if [ -z ${NODE_LEASE} ]
        then
		create_node_lease
	else
		# refresh the lease TTL, this wants to maintain a connection. probably a better way to do this
		# For now the workaround is to kill the pid.
		# THIS NEEDS VERIFICATION THAT IT RETURNS A PROPER EXIT CODE!
		( ETCDCTLPID=$BASHPID; (sleep 1; kill $ETCDCTLPID) & exec ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease keep-alive ${NODE_LEASE} )
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

${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID} | while read -r line
do 
	DESIRED_SERVICE_STATE=$(echo ${line} | sed 's/.*state://' | cut -d "," -f1)
	SERVICENAME=$(echo ${line} | | sed 's/.*servicename://' | cut -d "," -f1)
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
  	*)

done


exit 0
