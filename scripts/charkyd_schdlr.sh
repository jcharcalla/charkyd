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

# Start 3 monitors for this service
#
# Watch for new jobs

watch_scheduled()
{
        TASKW_CMD="${ETCDCTL_BIN} watch --prefix ${PREFIX_SCHEDULED}/ | grep "scheduler_node:none""
        echo ${TASKW_CMD}
        nohup ${TASKW_CMD} > ${WATCH_LOG} 2>&1&
        echo $! > ${SCHEDULE_WATCH_PID}
}


# If it is already running maybe it triggered this so run through and start things. 
if [ ! -f ${NODE_TASK_WATCH_PID} ]
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


# take the job, aka update key. then wait and query the key again to make 
# sure we have it claimed add something like "scheduler:thisnode"

# If no other schduler has claimed it move on

# on new job select nodes from correct rack, reagion, <alt>, node specific.
# choose node to run on

# Run deployment shell `git clone ansible && ansible-playbook ...`

# On success of installing the service, submit the job to node or nodes (maybe
# have monitoring service start the nodes like the previous version)

# If monitoring was requested start them now (need method for custome monitor,
# also, monitors should monitor each other and submit a new job if needed)

# once deployment has been sucseccful delete the entry and add it to a 
# /deployed/region/rack/nodeid location so that we can remove them if needed
# or at least know what was deployed where.
