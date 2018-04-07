#
# reporter.sh
#
# Reports node status to etcd V3
#
# Author: Jason Charcalla
# Copywrite 2018
#

# Prereqs:
# openssl for hash gen
# etcdctl https://github.com/coreos/etcd/releases

# Changelog:
# v.1 initial version
#

# config options
CONFIG=/etc/reporter.conf
ETCD_ENDPOINTS="192.168.79.129:2379,192.168.79.177:2379,192.168.79.178:2379"
export ETCDCTL_API=3
ETCDCTL_BIN=/tmp/etcd-v3.2.18-linux-amd64/etcdctl
# putting these here for now, they should be in the config file
REGION=region1
RACK=rack1


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
	echo "HOSTID=$(openssl rand -hex 32)" > ${CONFIG}
else
	source ${CONFIG}
fi

# Check if we read the right variable
if [ -z "$HOSTID" ]
then
	HOSTID=$(openssl rand -hex 32)
	echo ${HOSTID} > ${CONFIG}
fi

# Register the host to etcd, use a TTL on the key
# Values should be HASH, IP, FQDN, region, rack
# /nodes/<region>/<rack>/${HOSTID}
#echo "${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put /nodes/${REGION}/${RACK}/${HOSTID} \"fqdn:${FQDN},ipv4:${IPV4},ipv6:na\""
${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put /nodes/${REGION}/${RACK}/${HOSTID} \"fqdn:${FQDN},ipv4:${IPV4},ipv6:na\"

# Function for reporting updates on current service status. this was planed to have a TTL, looks like that
# is done as a lease now. No need to mess with that for the proof of concept.
report_service()
{
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put /service/status/${HOSTID}/${line} \"status:active,pid:na\"
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

	# systemctl start <service>
	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put /service/status/${HOSTID}/${line} \"status:restarting,pid:na\"
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

${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix /services/running/${HOSTID} | grep enabled| while read -r line; do if [ "$(systemctl is-active $(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2))" = 'active' ]; then report_service; else restart_service ;fi; done

exit 0
