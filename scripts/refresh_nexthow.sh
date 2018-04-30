#!/bin/bash
#
# Please configure according to your needs
#
function pc_remote_exec {
    sshpass -p nutanix/4u ssh -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null nutanix@10.21.${MY_HPOC_NUMBER}.39 "$@"
}
function pc_send_file {
    sshpass -p nutanix/4u scp -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null "$1" nutanix@10.21.${MY_HPOC_NUMBER}.39:/home/nutanix/"$1"
}

# Loging date format
#TODO: Make logging format configurable
#MY_LOG_DATE='date +%Y-%m-%d %H:%M:%S'
# Script file name
MY_SCRIPT_NAME=`basename "$0"`
# Derive HPOC number from IP 3rd byte
#MY_CVM_IP=$(ip addr | grep inet | cut -d ' ' -f 6 | grep ^10.21 | head -n 1)
MY_CVM_IP=$(/sbin/ifconfig eth0 | grep 'inet ' | awk '{ print $2}')
array=(${MY_CVM_IP//./ })
MY_HPOC_NUMBER=${array[2]}
# HPOC Password (if commented, we assume we get that from environment)
#MY_PE_PASSWORD='nx2TechXXX!'
MY_SP_NAME='SP01'
MY_CONTAINER_NAME='Default'
MY_IMG_CONTAINER_NAME='Images'
MY_DOMAIN_FQDN='ntnxlab.local'
MY_DOMAIN_NAME='NTNXLAB'
MY_DOMAIN_USER='administrator@ntnxlab.local'
MY_DOMAIN_PASS='nutanix/4u'
MY_DOMAIN_ADMIN_GROUP='SSP Admins'
MY_DOMAIN_URL="ldaps://10.21.${MY_HPOC_NUMBER}.40/"
MY_PRIMARY_NET_NAME='Primary'
MY_PRIMARY_NET_VLAN='0'
MY_SECONDARY_NET_NAME='Secondary'
MY_SECONDARY_NET_VLAN="${MY_HPOC_NUMBER}1"
# NEED TO UPDATE THESE

# From this point, we assume:
# IP Range: 10.21.${MY_HPOC_NUMBER}.0/25
# Gateway: 10.21.${MY_HPOC_NUMBER}.1
# DNS: 10.21.253.10,10.21.253.11
# Domain: nutanixdc.local
# DHCP Pool: 10.21.${MY_HPOC_NUMBER}.50 - 10.21.${MY_HPOC_NUMBER}.120
#
# DO NOT CHANGE ANYTHING BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING!!
#
# Source Nutanix environments (for PATH and other things)
source /etc/profile.d/nutanix_env.sh
# Logging function
function my_log {
    #echo `$MY_LOG_DATE`" $1"
    echo $(date "+%Y-%m-%d %H:%M:%S") $1
}
# Check if we got a password from environment or from the settings above, otherwise exit before doing anything
if [[ -z ${MY_PE_PASSWORD+x} ]]; then
    my_log "No password provided, exiting"
    exit -1
fi
my_log "My PID is $$"
my_log "Installing sshpass"
sudo rpm -ivh https://fr2.rpmfind.net/linux/epel/7/x86_64/Packages/s/sshpass-1.06-1.el7.x86_64.rpm

#unregister from PC
ncli multicluster remove-from-multicluster external-ip-address-or-svm-ips=10.21.${MY_HPOC_NUMBER}.39 username="admin" password="${MY_PE_PASSWORD}" force=true

#delete all VMs
acli -y vm.delete \* delete_snapshots=true

# Create AutoDC & power on
my_log "Create DC VM based on AutoDC image"
acli vm.create DC num_vcpus=2 num_cores_per_vcpu=1 memory=4G
acli vm.disk_create DC cdrom=true empty=true
acli vm.disk_create DC clone_from_image=AutoDC
acli vm.nic_create DC network=${MY_PRIMARY_NET_NAME} ip=10.21.${MY_HPOC_NUMBER}.40
my_log "Power on DC VM"
acli vm.on DC
# Need to wait for AutoDC to be up (30?60secs?)
my_log "Waiting 60sec to give DC VM time to start"
sleep 60

my_log "Creating Reverse Lookup Zone on DC VM"
sshpass -p nutanix/4u ssh -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null \
root@10.21.${MY_HPOC_NUMBER}.40 "samba-tool dns zonecreate dc1 ${MY_HPOC_NUMBER}.21.10.in-addr.arpa; service samba-ad-dc restart"

# Create AFS Client VM
my_log "Create AFSClient VM based on Windows2012 image"
acli uhura.vm.create_with_customize AFSClient container=Default memory=4G num_cores_per_vcpu=1 num_vcpus=2 sysprep_config_path=https://raw.githubusercontent.com/mattbator/stageworkshop/master/unattend.xml
acli vm.disk_create AFSClient cdrom=true empty=true
acli vm.disk_create AFSClient clone_from_image=Windows2012
acli vm.nic_create AFSClient network=${MY_PRIMARY_NET_NAME}
my_log "Power on AFSClient VM"
acli vm.on AFSClient

# Get UUID from cluster
my_log "Get UUIDs from cluster:"
MY_NET_UUID=$(acli net.get ${MY_PRIMARY_NET_NAME} | grep "uuid" | cut -f 2 -d ':' | xargs)
my_log "${MY_PRIMARY_NET_NAME} UUID is ${MY_NET_UUID}"
MY_CONTAINER_UUID=$(ncli container ls name=${MY_CONTAINER_NAME} | grep Uuid | grep -v Pool | cut -f 2 -d ':' | xargs)
my_log "${MY_CONTAINER_NAME} UUID is ${MY_CONTAINER_UUID}"
# Validate EULA on PE
my_log "Validate EULA on PE"
curl -u admin:${MY_PE_PASSWORD} -k -H 'Content-Type: application/json' -X POST \
  https://127.0.0.1:9440/PrismGateway/services/rest/v1/eulas/accept \
  -d '{
    "username": "SE",
    "companyName": "NTNX",
    "jobTitle": "SE"
}'
# Disable Pulse in PE
my_log "Disable Pulse in PE"
curl -u admin:${MY_PE_PASSWORD} -k -H 'Content-Type: application/json' -X PUT \
  https://127.0.0.1:9440/PrismGateway/services/rest/v1/pulse \
  -d '{
    "defaultNutanixEmail": null,
    "emailContactList": null,
    "enable": false,
    "enableDefaultNutanixEmail": false,
    "isPulsePromptNeeded": false,
    "nosVersion": null,
    "remindLater": null,
    "verbosityType": null
}'

# TODO: Parameterize DNS Servers & add secondary
MY_DEPLOY_BODY=$(cat <<EOF
{
  "resources": {
      "should_auto_register":true,
      "version":"5.6",
      "pc_vm_list":[{
          "data_disk_size_bytes":536870912000,
          "nic_list":[{
              "network_configuration":{
                  "subnet_mask":"255.255.255.128",
                  "network_uuid":"${MY_NET_UUID}",
                  "default_gateway":"10.21.${MY_HPOC_NUMBER}.1"
              },
              "ip_list":["10.21.${MY_HPOC_NUMBER}.39"]
          }],
          "dns_server_ip_list":["10.21.${MY_HPOC_NUMBER}.40"],
          "container_uuid":"${MY_CONTAINER_UUID}",
          "num_sockets":4,
          "memory_size_bytes":17179869184,
          "vm_name":"PC"
      }]
  }
}
EOF
)
curl -u admin:${MY_PE_PASSWORD} -k -H 'Content-Type: application/json' -X POST https://127.0.0.1:9440/api/nutanix/v3/prism_central -d "${MY_DEPLOY_BODY}"
my_log "Waiting for PC deployment to complete (Sleeping 15m)"
sleep 900
my_log "Sending PC configuration script"
pc_send_file stage_nexthow_pc.sh
# Execute that file asynchroneously remotely (script keeps running on CVM in the background)
my_log "Launching PC configuration script"
pc_remote_exec "MY_PE_PASSWORD=${MY_PE_PASSWORD} nohup bash /home/nutanix/stage_nexthow_pc.sh >> pcconfig.log 2>&1 &"
my_log "Removing sshpass"
sudo rpm -e sshpass
my_log "PE Configuration complete"
