#
# This is meant to be containerized
# This with the scheduler should be optional
#
# This script should check for at least 1 instance of the
# scheduler based on load
#
# This script should check for at lease 3 instances of 
# itself running, this should be an initial check
# with a longterm watcher running.
#
# To aviod confilits leaders should be doen with a timer
# variable. aka, i saw a job, is it there, wait, see if another
# node took it, then act.

# this script should have two modes, one to spawn watchers, 
# and another that is what the watcher spawns.

#
#
# charkyd_monitor.sh
#
# Watches service state with a new proccess, if it stop
# aka ttl expires, send it to the scheduler again.

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

# Variables
MONITOR_LEASE=45
MONITOR_LEASE_KEEPALIVE_PID=/var/run/charkyd_monitor_service_lease.pid

CONFIG=/etc/charkyd.conf
SCHEDULE_WATCH_PID=/var/run/charkyd_agent_taskwatch.pid
SCHED_LEASE_KEEPALIVE_PID=/var/run/charkyd_sched_lease_ka.pid
SCHEDULE_WATCH_LOG=/var/log/charkyd_schedwatch.log
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
SCHED_LEASE_TTL=15
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



# Functions go here

#
# Spawn a service lease
#
create_monitor_lease()
{
        MONITOR_LEASE=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease grant ${MONITOR_LEASE_TTL} | cut -d " " -f 2 )
        # echo "NODE_LEASE=${NODE_LEASE}" >> ${MEM_CONFIG}
        # Register the node and assign the new lease as it most likely does not exist.
        # ADD A CHECK HERE ENSURING THE NODE IS NOT ALREADY IN THE DB
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${MONITOR_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/monitor_service nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,epoch:${EPOCH}
        # Background a keepalive proccess for the node, so that if it stops the node key are removed
        KEEPA_CMD="${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease keep-alive ${MONITOR_LEASE}"
        nohup ${KEEPA_CMD} &
        echo $! > ${MONITOR_LEASE_KEEPALIVE_PID}
}

# Select hosts to be monitors
# The put here needs tweaked, but it should elect at least 1
elect_monitor()
{
        for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | grep -v ${HOSTID} | sort -R | head -n${MONITOR_ELECTS} | sed 's/.*nodeid://' | cut -d "," -f1);
                do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATE}/${REGION}/${RACK}/${i}/monitor_service servicename:monitor_service,unit_file:charkyd_monitor.service,replicas:1,nodeid:${i},epoch:${EPOCH},state:started;
        done
}


# check for the scheduler lease pid, if its not there start a new one, if it is kill the old
if [ ! -f ${MONITOR_LEASE_KEEPALIVE_PID} ]
then
        create_monitor_lease
else
        if [ ! `kill -0 $(cat ${SCHED_LEASE_KEEPALIVE_PID})` ]
        then
                create_monitor_lease
        fi
fi

# Notify systemd that we are ready
systemd-notify --ready --status="charkyd monitor services now running"

# syslog that we are runnign
logger -i "charkyd_scheduler: Monitor service now running."

#
# Check for running scheduler services.
#
MONITOR_COUNT=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${MONITOR_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/monitor_service | grep nodeid | wc -l)



#
# Make sure we we have 3 monitors running
#
if [ ${MONITOR_COUNT} -lt ${MONITOR_MIN} ]
then
# Launch one at a time, by selecting a node and setting it to run there
# make sure we don'tselet this host. could just be inverse grep
#
# No need to launch more than one, on start the next will launch one.
	elect_monitor
fi
#
# For every service that has requested a monitor, start a watcher and background
#

# for i in service mon
# do 
# 	check for pid
#	if no pid start watch in background

#
# Go into a loop around a watcher for long running
#
  # 
  # For every new thing that pops up spawn off a new watcher proccess

logger -i "charkyd_scheduler: Monitor service now exiting."

exit 0
