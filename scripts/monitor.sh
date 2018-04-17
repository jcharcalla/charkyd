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
CONFIG=/etc/reporter.conf
ETCD_ENDPOINTS="192.168.79.129:2379,192.168.79.177:2379,192.168.79.178:2379"
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
PREFIX_STATUS=/legacy_services/namespace_1/services/stauts
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

# if there are to many on this node, veto it by selecting another random node

# else check the time on the last time the service checked in that we are supposed to monitor.

# if the node hasent reported in for x threshold notify the provisioner service,
# or remove the service from that node and launch it again elsewhere

# if the service hasnt checked in ask the manipulator or reporter service to restart it
#

# might want to have the ability to run some sort of ansible job here. basically a recovery type of thing


