#
#
# This will check for newly scheduled services and build them locally
# using ansible. service should have a singl ansible role name. As in this
# should not be the role used to buld the actual container or service
# but one to place the unit files.
#
# start services as assigned by etcd V3
#
# Author: Jason Charcalla
# Copywrite 2018
#

# example
# etcd-v3.2.18-linux-amd64/etcdctl put /service/scheduled/region1/rack1/$(cat /etc/reporter.conf)/test_service1 \"replicas:1,type:ansible,source:playbook,opts:na,status:pending\"
#
#  ADD a service like this, ensure its in my ansible git repo
#[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl del --prefix /legacy_services/namespace_1/
#4
#[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/
#[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl put /legacy_services/namespace_1/services/scheduled/region1/rack1/$(cat /etc/reporter.conf| cut -d"=" -f2)/legacy_sample_service1 "servicename:legacy_sample_service1,unit_file:na,replicas:na,type:ansible,source:legacy_sample_service1.yml,opts:na,status:scheduled,state:enabled"
#OK
#[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/
#/legacy_services/namespace_1/nodes/region1/rack1/64415328457e89160e30ce2fdd8f7b5a0420a5e9034027940dea8f754a4e4d85
#"fqdn:localhost.charcalla.com,ipv4:127.0.0.1,ipv6:na,opts:na"
#/legacy_services/namespace_1/nodes/region1/rack1/72d750f80c44b41fb1a368cbfe7e1318894c5293949b0485c20eaee99d996b31
#"fqdn:localhost.charcalla.com,ipv4:127.0.0.1,ipv6:na,opts:na"
#/legacy_services/namespace_1/nodes/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3
#"fqdn:localhost.charcalla.com,ipv4:127.0.0.1,ipv6:na,opts:na"
#/legacy_services/namespace_1/services/scheduled/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3/legacy_sample_service1
#servicename:legacy_sample_service1,unit_file:na,replicas:na,type:ansible,source:legacy_sample_service1.yml,opts:na,status:scheduled,state:enabled
#[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/services
#/legacy_services/namespace_1/services/scheduled/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3/legacy_sample_service1
#servicename:legacy_sample_service1,unit_file:na,replicas:na,type:ansible,source:legacy_sample_service1.yml,opts:na,status:scheduled,state:enabled
#

# Prereqs:
# openssl for hash gen
# etcdctl https://github.com/coreos/etcd/releases
# git
# ansible

# Changelog:
# v.1 initial version
#

# config options (some of these, llike node id, regio, and rack should be stored as factors)
CONFIG=/etc/reporter.conf
PENDING_SLEEP=10s
ETCD_ENDPOINTS="192.168.79.61:2379,192.168.79.62:2379,192.168.79.63:2379"
export ETCDCTL_API=3
ETCDCTL_BIN=/usr/local/bin/etcdctl
GIT_REPO=/reflection_pool/projects/git/ansible.git/
GIT_LOCAL_PATH=/root/ansible/
ANSIBLE_PLAYBOOK_PATH=${GIT_LOCAL_PATH}
ANSIBLE_PLAYBOOK_BIN=/usr/bin/ansible-playbook
# putting these here for now, they should be in the config file
REGION=region1
RACK=rack1
UUID_LENGTH=12
SERVICE_UUID_LENGTH=6

PREFIX_SCHEDULED=/legacy_services/namespace_1/services/scheduled
PREFIX_RUNNING=/legacy_services/namespace_1/services/running
PREFIX_PAUSED=/legacy_services/namespace_1/services/paused
PREFIX_MONITOR=/legacy_services/namespace_1/services/monitor
PREFIX_STATUS=/legacy_services/namespace_1/services/status
PREFIX_TERMINATED=/legacy_services/namespace_1/services/terminated
PREFIX_ERASED=/legacy_services/namespace_1/services/erased
PREFIX_NODES=/legacy_services/namespace_1/nodes

FQDN=`nslookup $(hostname -f) | grep "Name:" | cut -d":" -f2 | xargs`
IPV4=`nslookup $(hostname -f) | grep "Name:" -A1 | tail -n1 | cut -d":" -f2 | xargs`

EPOCH=$(date +%s)


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

### Define functions
# function for if a new service is found.
build_service()
{
   # Gather variables, yep this should be some awk foo! Or some better json way
   SERVICENAME=${SERVICENAME}
   UNIT_FILE=$(echo ${line} | cut -d "," -f 2 | cut -d ":" -f2)
   REPLICAS=$(echo ${line} | cut -d "," -f 3 | cut -d ":" -f2)
   TYPE=$(echo ${line} | cut -d "," -f 4 | cut -d ":" -f2)
   SOURCE=$(echo ${line} | cut -d "," -f 5 | cut -d ":" -f2)
   OPTIONS=$(echo ${line} | cut -d "," -f 6 | cut -d ":" -f2)


elect_monitor

   # If we dont have enough resources, lets just start a watcher and let another node take it.


   # if were ansible do stuff, if not tough shit.
   case $TYPE in
	bash|BASH|Bash)
	   ;;
	puppet|PUPPET|Puppet)
	   ;;
	ansible|ANSIBLE|Ansible)

	   echo "launching local ansible run"
	   logger -i "lecgacy_builder: Building new service name:${SERVICENAME} via ${TYPE}"

   # update git repo.
  	   cd ${GIT_LOCAL_PATH} && git pull
   
   #wait
           sleep 10s
	   echo "Sleeping"

   # ensure no other nodes say the service is currently running
   # 	  do anoter etcd poll here...

   # localy build / install service file, import image into docker / etc.
   # Need to somehow report this status to something... could change pending to failed and log output locally for retrival
          ${ANSIBLE_PLAYBOOK_BIN} ${ANSIBLE_PLAYBOOK_PATH}${SOURCE} --extra-vars "legacy_servicename=${SERVICENAME}"
   # add service running que, marked as pending
         # etcd-v3.2.18-linux-amd64/etcdctl put /legacy_services/namespace_1/running/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3/test_service2 "name:test_service2,replicas:1,type:ansible,source:playbook,opts:na,status:provisioned,state:enabled"
	 ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_RUNNING}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME} servicename:${SERVICENAME},unit_file:${UNIT_FILE},replicas:${REPLICAS},type:${TYPE},source:${SOURCE},opts:${OPTIONS},status:provisioned,state:enabled,epoch:${EPOCH}

   # wait for initaial statu entry from reporter (needs new name) service

   # if replica count is higher than 1 add it to a replicas key, or somehow have a key - actually let the monitor nodes deal with it
   # 
   # select 3 nodes to be monitors from the availible nodes list, could be in the rack / region area 
   # for i in $(etcd-v3.2.18-linux-amd64/etcdctl get --prefix /legacy_services/namespace_1/nodes/ | grep nodeid | sort -R | head -n3 | cut -d "," -f1 | cut -d ":" -f 2); do etcd-v3.2.18-linux-amd64/etcdctl put /legacy_services/namespace_1/monitor/region1/rack1/${i}/service test123; done
   for i in $(${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_NODES} | grep nodeid | sort -R | head -n3 | cut -d "," -f1 | cut -d ":" -f 2); do EPOCH=$(date +%s); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_MONITOR}/${REGION}/${RACK}/${i}/${SERVICENAME} servicename:${SERVICENAME},unit_file:${UNIT_FILE},replicas:${REPLICAS},nodeid:${HOSTID},epoch:${EPOCH}; done

   # remove from the scheduled service que, if all replicas are up. At this point the service should now be watched and will auto reque or restart if needed
   # /legacy_services/namespace_1/services/scheduled/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3/legacy_sample_service10
   ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} del ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME}
   
   # Select 3 hosts to monitor this service
   	 ;;
       *)
  esac
}

# Adjust sleep time based on how many services / resources we are using

# check for new scheduled services destined to run on this node
   # If none go ahead, if there is run the build service function

### Check for pending services assigned to this specific node.
   # /service/scheduled/<region id>/<rack id>/<node id>/<service name>
   ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID} | grep scheduling | while read -r line; do echo ${line}; SERVICE_UUID=$(openssl rand -hex ${SERVICE_UUID_LENGTH}); SERVICENAME=$(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2)${SERVICE_UUID};NEWLINE=$(echo ${line} | sed 's/scheduling/provisioning/g'); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} ${NEWLINE}; echo "newline=${NEWLINE}"; echo "servicename=${SERVICENAME}" ; build_service ; done
# get

   # put

   #[root@localhost ~]# etcd-v3.2.18-linux-amd64/etcdctl get --prefix /service/scheduled/region1/rack1/$(cat /etc/reporter.conf)/ |grep pending
   #"name:test_service1,replicas:1,type:ansible,source:playbook,opts:na,status:pending"

# Check for any schduled services that needs any place to run, should probably run this multiple
# times in order of precidence. Node, Rack, Region, Any.

# /service/scheduled/<region>/<rack>/<service name>
# get

# put

# /service/scheduled/<region>/<service name>

# /service/scheduled/global/<service name>
  # global services with +1 replicas should check for balanced locality.

exit 0
