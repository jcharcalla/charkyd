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
MONITOR_LEASE_KEEPALIVE_PID=

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
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${MONITOR_LEASE} ${PREFIX_MONITORS}/${REGION}/${RACK}/${HOSTID} nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,epoch:${EPOCH}
        # Background a keepalive proccess for the node, so that if it stops the node key are removed
        KEEPA_CMD="${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease keep-alive ${MONITOR_LEASE}"
        nohup ${KEEPA_CMD} &
        echo $! > ${MONITOR_LEASE_KEEPALIVE_PID}
}

#
# Check for running scheduler services.
#


#
# Make sure we we have 3 monitors running
#
# Launch one at a time, by selecting a node and setting it to run there
#

#
# For every service that has requested a monitor, start a watcher and background
#

#
# Go into a loop around a watcher for long running
#
  # 
  # For every new thing that pops up spawn off a new watcher proccess
