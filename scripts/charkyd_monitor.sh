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
PID_PATH=/var/run/
MONITOR_WATCH_PID=/var/run/charkyd_monitor_watch.pid
MONITOR_SERVICE_WATCH_PID=/var/run/charkyd_monitor_servicewatch.pid
SCHED_LEASE_KEEPALIVE_PID=/var/run/charkyd_sched_lease_ka.pid
MONITOR_WATCH_LOG=/var/log/charkyd_monitorwatch.log
MONITOR_SERVICE_WATCH_LOG=/var/log/charkyd_monitor_servicewatch.log
ELECTION_SLEEP=5

# config options (these should be stored as factors on the node)
# putting these here for now, they should be in the config file
ETCD_ENDPOINTS="{{ charkyd_etcd_endpoints }}"
export ETCDCTL_API=3
ETCDCTL_BIN=/usr/local/bin/etcdctl
REGION=region1
RACK=rack1
UUID_LENGTH=12
API_VERSION=v1
NAMESPACE=cluster1
MONITOR_LEASE_TTL=15
PREFIX_SCHEDULED=/charkyd/${API_VERSION}/${NAMESPACE}/services/scheduled
PREFIX_STATE=/charkyd/${API_VERSION}/${NAMESPACE}/services/state
#PREFIX_PAUSED=/charkyd/${API_VERSION}/${NAMESPACE}/services/paused
PREFIX_MONITOR=/charkyd/${API_VERSION}/${NAMESPACE}/services/monitor
PREFIX_STATUS=/charkyd/${API_VERSION}/${NAMESPACE}/services/status
#PREFIX_TERMINATED=/charkyd/${API_VERSION}/${NAMESPACE}/services/terminated
#PREFIX_ERASED=/charkyd/${API_VERSION}/${NAMESPACE}/services/erased
PREFIX_NODES=/charkyd/${API_VERSION}/${NAMESPACE}/nodes
# I should have a flow table so sdn switches can use it to build networks
MONITOR_MIN=3
SCHEDULER_MIN=1
MONITOR_ELECTS=1

# load some config options, at one point i thought i had a 
# method for sanatizing this.
if [ ! -f ${CONFIG} ]
then
	echo "Config not availible, exiting..."
	logger -i "charkyd_monitor: ERROR, no config file, exiting..."
	exit 1;
else
        source ${CONFIG}
        # Check if we sourced the HOSTID var from the config, if not this is a new host so make a new one
fi
# Functions go here

#
# Spawn a service lease
#
create_monitor_lease()
{
	echo "debug monitor lease start"
        MONITOR_LEASE=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease grant ${MONITOR_LEASE_TTL} | cut -d " " -f 2 )
        # echo "NODE_LEASE=${NODE_LEASE}" >> ${MEM_CONFIG}
        # Register the node and assign the new lease as it most likely does not exist.
        # ADD A CHECK HERE ENSURING THE NODE IS NOT ALREADY IN THE DB
        ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put --lease=${MONITOR_LEASE} ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/monitor_service nodeid:${HOSTID},fqdn:${FQDN},ipv4:${IPV4},ipv6:na,opts:na,epoch:${EPOCH}
        # Background a keepalive proccess for the node, so that if it stops the node key are removed
        KEEPA_CMD="${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} lease keep-alive ${MONITOR_LEASE}"
        nohup ${KEEPA_CMD} &
        echo $! > ${MONITOR_LEASE_KEEPALIVE_PID}
	echo "debug monitor lease stop"
}

# this was supposed to monitor the status of the monitor que. as in should this host be a monitor?
# seems redundant or not needed. elected monitors should be started by the agent and using its queue
# 
# Still needed, unless I just by default monitor the state of all services.

#watch_monitor_requests()
#{       
#        MONW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_MONITOR}/ | grep "nodeid:""
#        echo ${MONW_CMD}
#        nohup ${MONW_CMD} > ${MONITOR_WATCH_LOG} 2>&1&
#        echo $! > ${MONITOR_WATCH_PID}
#	echo "debug monitor request"
#}

# Watch the status of an individual service status. Spawn these off seperatly
# Will need individual service pids
# and a way to tail the log and react when something goes wrong.
#
# Wait a minute, this should simply monitor all service statuses
monitor_service()
{       
        #MONSERVICEW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_STATUS}/${nodeid} | grep "servicename:${servicename}""
        MONSERVICEW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_STATUS} | grep "nodeid:""
        echo ${MONSERVICEW_CMD}
        nohup ${MONSERVICEW_CMD} >> ${MONITOR_SERVICE_WATCH_LOG} 2>&1&
        echo $! > ${MONITOR_SERVICE_WATCH_PID}
	echo "debug monitor service"
}

# Select hosts to be monitors
# The put here needs tweaked, but it should elect at least 1
elect_monitor()
{
	echo "debug elect monitor start"
        for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | grep -v ${HOSTID} | sort -R | head -n${MONITOR_ELECTS} | sed 's/.*nodeid://' | cut -d "," -f1);
                do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATE}/${REGION}/${RACK}/${i}/monitor_service servicename:monitor_service,unit_file:charkyd_monitor.service,replicas:1,nodeid:${i},epoch:${EPOCH},state:started;
        done
	echo "${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATE}/${REGION}/${RACK}/${i}/monitor_service servicename:monitor_service,unit_file:charkyd_monitor.service,replicas:1,nodeid:${i},epoch:${EPOCH},state:started"
	echo "${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | grep -v ${HOSTID} | sort -R | head -n${MONITOR_ELECTS} | sed 's/.*nodeid://' | cut -d "," -f1"
	echo "debug elect monitor end"
}

# Verify that this node is scheduled to have a running monitor on it.

# check for the monitor lease pid, if its not there start a new one, if it is kill the old
if [ ! -f ${MONITOR_LEASE_KEEPALIVE_PID} ]
then
        create_monitor_lease
else
        if [ ! `kill -0 $(cat ${MONITOR_LEASE_KEEPALIVE_PID})` ]
        then
                create_monitor_lease
        fi
fi

# Notify systemd that we are ready
systemd-notify --ready --status="charkyd monitor services now running"

# syslog that we are runnign
logger -i "charkyd_monitor: Monitor service now running."

#
# Check for running scheduler services.
#
echo "check for running monitors"
MONITOR_COUNT=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/monitor_service | grep nodeid | wc -l)



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

# Make sure we are running a scheduler? Only if it's requested monitoring I guess.
# ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/scheduler_service
SCHEDULER_COUNT=$(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_STATUS}/${REGION}/${RACK}/${HOSTID}/scheduler_service | grep nodeid | wc -l)


if [ ${SCHEDULER_COUNT} -lt ${SCHEDULER_MIN} ]
then
# I should proable have a mechanism here to take, wait, and then deploy the scheduler
        for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | grep -v ${HOSTID} | sort -R | head -n${MONITOR_ELECTS} | sed 's/.*nodeid://' | cut -d "," -f1);
                do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_STATE}/${REGION}/${RACK}/${i}/scheduler_service servicename:scheduler_service,unit_file:charkyd_schdlr.service,replicas:1,nodeid:${i},epoch:${EPOCH},state:started;
        done
fi

#
# For every service that has requested a monitor, start a watcher and background
#

# touch, or clear the monitor_service_watch_log file. this is in case there are no 
# services to watch. Also, this application is not really meant to be stateful
#touch ${MONITOR_SERVICE_WATCH_LOG}
# NOTE: I should at least be watching a scheduler proccess shouldnt I?
echo "#### HEAD ${EPOCH} ####" > ${MONITOR_SERVICE_WATCH_LOG}

# for i in service mon
echo "debug 1... ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_MONITOR} | grep nodeid | sort -R"
for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_MONITOR} | grep nodeid | sort -R);
do # Check for pid
	echo "debug 1.5"
nodeid=$(echo ${i} | sed 's/.*nodeid://' | cut -d "," -f1)
servicename=$(echo ${i} | sed 's/.*servicename://' | cut -d "," -f1)
MONITOR_KEEPALIVE_PID=${PID_PATH}${nodeid}_${servicename}.pid
# check for the scheduler lease pid, if its not there start a new one, if it is kill the old
if [ ! -f ${MONITOR_KEEPALIVE_PID} ]
then
        monitor_service
	echo "starting monitor_service"
else
        if [ ! `kill -0 $(cat ${MONITOR_KEEPALIVE_PID})` ]
        then
                monitor_service
	echo "re-starting monitor_service"
        fi
fi
#	if no pid start watch in background
done

#
# Go into a loop around a watcher for long running
#

# Start the function
# If the scheduler watcher pid is already running maybe it triggered this so run through and start things.
#if [ ! -f ${MONITOR_WATCH_PID} ]
#then
#        watch_monitor_requests
#	echo "starting watch_monitor_requests"
#else
#        if [ ! `kill -0 $(cat ${MONITOR_WATCH_PID})` ]
#        then
#                watch_monitor_requests
#	echo "re-starting watch_monitor_requests"
#        fi
#fi

# tail the log file
# not sure how to best do this, I need to watch the monitor_service_watch_log to identify and
# re-schedule services when they fail. however this is not tailing the right log file.
# That proccess in its;ef should probably be spawned off in the background.
#
# Additionally I need to watch the monitor queue, and monitor all new services that want monitored.
# Or to simplify, I could just monitor every service.
#
# It may be better to have a seperate monior queue. THis would allow monitoring services and hosts?
# Still thinking, depends on how monitors are requested.
#
# If I monitor all services. what do I do in case of emergency? this could be in the monitor 
# queue. or even two queues. What I want monitored, and what the current status is.
#
# I could, on monitored services, convert the status to a ttl. this could also alow for 
# role based permissions
#
echo "debug 2"
tail -fn0 ${MONITOR_SERVICE_WATCH_LOG} | while read wline ;
do
  # 
  # For every new thing that pops up spawn off a new watcher proccess
nodeid=$(echo ${wline} | sed 's/.*nodeid://' | cut -d "," -f1)
servicename=$(echo ${wline} | sed 's/.*servicename://' | cut -d "," -f1)
MONITOR_KEEPALIVE_PID=${PID_PATH}${nodeid}_${servicename}.pid
# check for the scheduler lease pid, if its not there start a new one, if it is kill the old
if [ ! -f ${MONITOR_KEEPALIVE_PID} ]
then
        monitor_service
else
        if [ ! `kill -0 $(cat ${MONITOR_KEEPALIVE_PID})` ]
        then
                monitor_service
        fi
fi
#       if no pid start watch in background
  # failback?
done


logger -i "charkyd_scheduler: Monitor service now exiting."

exit 0
