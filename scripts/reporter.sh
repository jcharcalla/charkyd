#
# reporter.sh
#
# Reports node status to etcd V3 and restarts services if needed
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

# config options (these should be stored as factors on the node)
CONFIG=/etc/reporter.conf
ETCD_ENDPOINTS="192.168.79.61:2379,192.168.79.62:2379,192.168.79.63:2379"
export ETCDCTL_API=3
ETCDCTL_BIN=/usr/local/bin/etcdctl
# putting these here for now, they should be in the config file
REGION=region1
RACK=rack1
UUID_LENGTH=12
PREFIX_SCHEDULED=/legacy_services/namespace_1/services/scheduled
PREFIX_RUNNING=/legacy_services/namespace_1/services/running
PREFIX_PAUSED=/legacy_services/namespace_1/services/paused
PREFIX_MONITOR=/legacy_services/namespace_1/services/monitor
PREFIX_STATUS=/legacy_services/namespace_1/services/status
PREFIX_TERMINATED=/legacy_services/namespace_1/services/terminated
PREFIX_ERASED=/legacy_services/namespace_1/services/erased
PREFIX_NODES=/legacy_services/namespace_1/nodes
MONITOR_MIN=3
MONITOR_ELECTS=1

EPOCH=$(date +%s)
# I need some logic to define the availible resources on this node
# to report them back to the DB, also keep track of availible resources
NUMPROC=$(nproc --all)
TOTMEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
# I know, math this way rounds down to the nearest GB. Which probacly
# isnt a bad thing
TOTMEM=$((TOTMEM/102400))

FQDN=`nslookup $(hostname -f) | grep "Name:" | cut -d":" -f2 | xargs`
IPV4=`nslookup $(hostname -f) | grep "Name:" -A1 | tail -n1 | cut -d":" -f2 | xargs`


#
# Parse options
#
# etcd servers, regions, rack, etc
# etcdctl path

# check for a config file
# if not there write it, if it is read out our node ID hash

if [ ! -f ${CONFIG} ]
then
	echo "HOSTID=$(openssl rand -hex ${UUID_LENGTH})" > ${CONFIG}
else
	source ${CONFIG}
fi

# Check if we read the right variable
if [ -z ${HOSTID} ]
then
	HOSTID=$(openssl rand -hex ${UUID_LENGTH})
	echo "HOSTID=${HOSTID}" > ${CONFIG}
fi

# Register the host to etcd, use a TTL on the key
# Values should be HASH, IP, FQDN, region, rack
# /nodes/<region>/<rack>/${HOSTID}
#echo "${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put /nodes/${REGION}/${RACK}/${HOSTID} \"fqdn:${FQDN},ipv4:${IPV4},ipv6:na\""
# This should only update periodically to allow the scheuler to know the host is live. Needs a counter.

#
# I could for giggles encrypt the values i send, thus requiring all nodes to know a secret...
# Or I could use etcd roles.
#
${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_NODES}/${REGION}/${RACK}/${HOSTID} nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,numproc:${NUMPROC},totmem:${TOTMEM},epoch:${EPOCH}

elect_monitor()
{
        for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | sort -R | head -n${MONITOR_ELECTS} | cut -d "," -f1 | cut -d ":" -f 2);
                do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_MONITOR}/${REGION}/${RACK}/${i}/${SERVICENAME} servicename:${SERVICENAME},unit_file:${UNIT_FILE},replicas:${REPLICAS},nodeid:${HOSTID},epoch:${EPOCH};
        done
}

# Function for reporting updates on current service status. this was planed to have a TTL, looks like that
# is done as a lease now. No need to mess with that for the proof of concept.
report_service()
{
	# see if this service is being whatched by at least n number
	#etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/services/monitor/region1/rack1/ | grep servicename | grep legacy_sample_service10 | wc -l
	MONITORS_RUNNING=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_MONITOR}/${REGION}/${RACK}/| grep servicename | grep ${SERVICENAME} | wc -l)
	if [ ${MONITORS_RUNNING} -lt ${MONITOR_MIN} ]
	then
		# elect a new monitor node to watch this service.
		elect_monitor
	fi
	# In reality this function should write to a counter somewhere so the put only occurs every Nth time.
	# A lease should then be placed on the ket in etcd. this should limit traffic to every 5 to 10 minutes.
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:active,pid:na,nodeid:${HOSTID},epoch:${EPOCH}
	# get a list of all the monitor nodes cuttently watching this service and verify they are still 3 and if the time stamp is too old
	# select a new node from the nodes list to monitor.
}

# Function for starting missing services.
restart_service()
{
	# not really going to do any error checking here, although I may want to try to grab the pid.
	# errors should be picked up netx time around, and if it's not running after sat three trys
	# then whatever watcher/scheduler service I come up with should reschedule it elsewhere or
	# throw an error somewhere. NOTE: services should be configured and started/stoped via and
	# ansible hook, this script is for monitoring of and automation around when things need to
	# change

	#systemctl restart ${SERVICENAME}.service
	systemctl stop ${SERVICENAME}.service
	systemctl start ${SERVICENAME}.service
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:restarting,pid:nai,nodeid:${HOSTID},epoch:${EPOCH}
}

start_service()
{
        systemctl start ${SERVICENAME}.service
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} service:${SERVICENAME},status:starting,pid:na,nodeid:${HOSTID},epoch:${EPOCH}
        }



# Check for services I should be running
# /service/running/${HOSTID}/<service name>
# Note, this could be done here, or by a launcher script that runs ansible from a remote location
# remote launching involes complexity of needing SSH keys, this could be doable if the launcher service
# is run in a container that mounts in the keys from the underlying hypervisor secure storage or
# some other vault type mechanism
#
# Report on the services currently running on this host. All services should have some sort of 
# easily identifiable prefix so we can use a for loop around "systemctl is-active"
# /service/status/${HOSTID}/<service name>
#/tmp/etcd-v3.2.18-linux-amd64/etcdctl --endpoints=192.168.79.129:2379,192.168.79.177:2379,192.168.79.178:2379 get --prefix /services/running/f85c215ac6ee4e7d749df30adb986a2804977b3c057f553d29ff959a124efcab | grep enabled| while read -r line; do if [ "$(systemctl is-active $(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2))" = 'active' ]; then "submit function here" ;fi; done
#
${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_RUNNING}/${REGION}/${RACK}/${HOSTID} | grep "state:enabled"| while read -r line; do if [ "$(systemctl is-active $(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2))" = 'active' ]; then SERVICENAME=$(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2); report_service; else SERVICENAME=$(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2); restart_service ;fi; done

 # Use a similar technique to stop services here
 #  maybe short random sleep here.

exit 0
