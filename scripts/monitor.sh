#
# monitor.sh
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
SERVICE_TIMEOUT=60
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

# I need some logic to define the availible resources on this node
# to report them back to the DB, also keep track of availible resources

# list nodes function

FQDN=`nslookup $(hostname -f) | grep "Name:" | cut -d":" -f2 | xargs`
IPV4=`nslookup $(hostname -f) | grep "Name:" -A1 | tail -n1 | cut -d":" -f2 | xargs`

##
## Look at list of services to monitor by this host.
##

# etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/services/monitor/region1/rack1/$(cat /etc/reporter.conf| cut -d"=" -f2) | grep servicename

# if there are to many on this node, veto it by selecting another random node

# else check the time on the last time the service checked in that we are supposed to monitor.
# for i in $(etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/services/monitor/region1/rack1/$(cat /etc/reporter.conf| cut -d"=" -f2) | grep servicename); do echo ${i}; done

for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_MONITOR}/${REGION}/${RACK}/${HOSTID} | grep servicename)
do
	SERVICENAME=$(echo ${i} | cut -d "," -f1 | cut -d ":" -f2)
	# UNITFILE
	# REPLICAS
	SERVICE_NODEID=$(echo ${i} | cut -d "," -f4 | cut -d ":" -f2)
	SERVICE_EPOCH=$(echo ${i} | cut -d "," -f5 | cut -d ":" -f2)

	# If the service being monitored is on this node, its probably a report from the monitor node
	# so we should ensure it's current, and if not evict and pick a new monitor node.
	#if [ ${SERVICE_NODEID} == ${HOSTID} ]
	#then
	if [ ${SERVICENAME} == "monitor" ]
	then
		# Check that the node doing the monitoring is up
		MONITORNODE_STRING=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODE}/${REGION}/${RACK}/${SERVICE_NODEID})
		MONITORNODE_EPOCH=$(echo ${MONITORNODE_STRING} | grep nodeid | cut -d "," -f8 | cut -d ":" -f2)

		if [ ${MONITORNODE_EPOCH} -le $((`date +%s` - ${MONITOR_TIMEOUT})) ]
		then
			# Remove the monitor services from possibly dead node
			# if not, evict it and elect a new one
			${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} del --prefix ${PREFIX_MONITOR}/${REGION}/${RACK}/${SERVICE_NODEID}
			# Elect a new node to monitor this service
			# this should be a function
			# Or, this should be done elswhere, and we should check to see
			# if there are 3, this check will confirm their validity once added.

			# Maybe evict the node from the cluster
			${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} del --prefix ${PREFIX_NODE}/${REGION}/${RACK}/${SERVICE_NODEID}
		fi

	else
		# Check that the service is current
		SERVICESTATUS_STRING=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATUS}/${REGION}/${RACK}/${SERVICE_NODEID}/${SERVICENAME})
	        SERVICESTATUS_EPOCH=$(echo ${MONITORNODE_STRING} | grep nodeid | cut -d "," -f5 | cut -d ":" -f2)

		if [ ${MONITORNODE_EPOCH} -le $((`date +%s` - ${MONITOR_TIMEOUT})) ]
                then
			
			# check that the node is current
			# evict the node if its down.
	                SERVICENODE_EPOCH=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODE}/${REGION}/${RACK}/${SERVICE_NODEID})
                	SERVICENODE_EPOCH=$(echo ${MONITORNODE_STRING} | grep nodeid | cut -d "," -f8 | cut -d ":" -f2)

                	if [ ${MONITORNODE_EPOCH} -le $((`date +%s` - ${MONITOR_TIMEOUT})) ]
                	then
                        	# Remove the monitor services from possibly dead node
                        	# if not, evict it and elect a new one
                        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} del --prefix ${PREFIX_MONITOR}/${REGION}/${RACK}/${SERVICE_NODEID}
                        	# Maybe evict the node from the cluster
                        	${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} del --prefix ${PREFIX_NODE}/${REGION}/${RACK}/${SERVICE_NODEID}
			fi
			# re-schedule the service if its not responded
			# delete the service from the node

			# reschedule it
		else
			# Inform the node running the service that we are watching it elsewhere in the cluster
			${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_MONITOR}/${REGION}/${RACK}/${SERVICE_NODEID}/${SERVICENAME} servicename:monitor,unit_file:na,replicas:na,nodeid:${HOSTID},epoch:${EPOCH}
		fi




	fi


# if the node hasent reported in for x threshold notify the provisioner service,
# or remove the service from that node and launch it again elsewhere
        # if [ $EPOCH -le $((`date +%s` - 10)) ]; then echo YES; fi
	if [ $SERVICE_EPOCH -le $((`date +%s` - ${SERVICE_TIMEOUT})) ];
	then
	# if the service hasnt checked in ask the manipulator or reporter service to restart it
	# At this point the service should have been restarted on the node, either its broken
	# or maybe the node is down, check node status next. and reschedule if the node is down
	#
	# I had some thoughts about timing of all these things, it probably wouldnt matter if 3 nodes rescheduled at
	# the same time, as long as the node starting the service waits and verifies it assignment afer
	# a few seconds. we could watch service epochs too
		echo "Service: ${SERVICENAME} not running!"
        else
		# Report that the monitor is running so the above step on the node running the service can
		# monitor the monitor
		echo "Service UP!"
	fi
# might want to have the ability to run some sort of ansible job here. basically a recovery type of thing

done
