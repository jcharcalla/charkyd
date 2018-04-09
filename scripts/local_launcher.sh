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
ETCD_ENDPOINTS="192.168.79.129:2379,192.168.79.177:2379,192.168.79.178:2379"
export ETCDCTL_API=3
ETCDCTL_BIN=/usr/local/bin/etcdctl
GIT_REPO=/reflection_pool/projects/git/ansible.git/
GIT_LOCAL_PATH=/root/ansible/
ANSIBLE_PLAYBOOK_PATH=${GIT_LOCAL_PATH}
ANSIBLE_PLAYBOOK_BIN=/usr/bin/ansible-playbook
# putting these here for now, they should be in the config file
REGION=region1
RACK=rack1
PREFIX_SCHEDULED=/legacy_services/namespace_1/scheduled
PREFIX_RUNNING=/legacy_services/namespace_1/running
PREFIX_PAUSED=/legacy_services/namespace_1/paused
PREFIX_STATUS=/legacy_services/namespace_1/stauts
PREFIX_TERMINATED=/legacy_services/namespace_1/terminated
PREFIX_ERASED=/legacy_services/namespace_1/erased


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
if [ -z ${HOSTID} ]
then
        HOSTID=$(openssl rand -hex 32)
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

   # if were ansible do stuff, if not tough shit.
   case $TYPE in
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
          ${ANSIBLE_PLAYBOOK_BIN} -i ${ANSIBLE_INVENTORY} ${SOURCE}
   # add service running que, marked as pending
         # etcd-v3.2.18-linux-amd64/etcdctl put /legacy_services/namespace_1/running/region1/rack1/a41f74d9c1282180c51380b3690cc4f38627e715a41aae69b24fd6f0a813bbe3/test_service2 "name:test_service2,replicas:1,type:ansible,source:playbook,opts:na,status:provisioned,state:enabled"
	 ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_RUNNING}/${REGION}/${RACK}/${HOSTID}/${SERVICE_NAME} \"servicename:${SERVICENAME},unit_file:${UNIT_FILE},replicas:${REPLICAS},type:${TYPE},source:${SOURCE},opts:${OPTIONS},status:provisioned,state:enabled\"

   # wait for initaial statu entry from reporter (needs new name) service

   # if replica count is higher than 1 add it to a replicas key, or somehow have a key

   # remove from the scheduled service que, if all replicas are up.
   	 ;;
       *)
  esac
}

# Adjust sleep time based on how many services / resources we are using

# check for new scheduled services destined to run on this node
   # If none go ahead, if there is run the build service function

### Check for pending services assigned to this specific node.
   # /service/scheduled/<region id>/<rack id>/<node id>/<service name>
${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} get --prefix ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID} | grep pending| while read -r line; do echo ${line}; SERVICENAME=$(echo ${line} | cut -d "," -f 1 | cut -d ":" -f2);NEWLINE=$(echo ${line} | sed 's/pending/provisioning/g'); ${ETCDCTL_BIN} --endpoints=${ETCD_ENDPOINTS} put ${PREFIX_SCHEDULED}/${REGION}/${RACK}/${HOSTID}/${SERVICENAME} ${NEWLINE}; echo ${NEWLINE}; echo build_service ; done
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
