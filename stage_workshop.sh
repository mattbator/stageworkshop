#!/bin/bash

WORKSHOPS=("Calm Introduction Workshop" \
#"Citrix Desktop on AHV Workshop" \
#"Tech Summit 2018" \
"Change Cluster Input File" \
"Quit")

function remote_exec {
  sshpass -p $MY_PE_PASSWORD ssh -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null nutanix@$MY_PE_HOST "$@"
}

function send_file {
  FILENAME="${1##*/}"

  sshpass -p $MY_PE_PASSWORD scp -o StrictHostKeyChecking=no -o GlobalKnownHostsFile=/dev/null -o UserKnownHostsFile=/dev/null "$1" nutanix@$MY_PE_HOST:/home/nutanix/"${FILENAME}"
}

# Get list of clusters from user
function get_file {
  read -p 'Cluster Input File: ' CLUSTER_LIST

  if [ ! -f ${CLUSTER_LIST} ]; then
    echo "FILE DOES NOT EXIST!"
    get_file
  fi

  select_workshop
}

# Get workshop selection from user, set script files to send to remote clusters
function select_workshop {
  PS3='Select an option: '
  select WORKSHOP in "${WORKSHOPS[@]}"
  do
    case $WORKSHOP in
      "Calm Introduction Workshop")
      PE_CONFIG=stage_calmhow.sh
      PC_CONFIG=stage_calmhow_pc.sh
      break
      ;;
      #"Citrix Desktop on AHV Workshop")
      #PE_CONFIG=stage_citrixhow.sh
      #PC_CONFIG=stage_citrixhow_pc.sh
      #break
      #;;
      #"Tech Summit 2018")
      #PE_CONFIG=stage_ts18.sh
      #PC_CONFIG=stage_ts18_pc.sh
      #break
      #;;
      "Change Cluster Input File")
      get_file
      break
      ;;
      "Quit")
      exit
      ;;
      *) echo "Invalid entry, please try again.";;
    esac
  done

  read -p "Are you sure you want to stage ${WORKSHOP} to the clusters in ${CLUSTER_LIST}? Your only 'undo' option is running Foundation on your cluster(s) again. (Y/N)" -n 1 -r

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    stage_clusters
  else
    echo
    echo "Come back soon!"
  fi
}

# Set script files to send to remote clusters based on command line argument
function set_workshop {

  case ${WORKSHOPS[$((${WORKSHOP_NUM}-1))]} in
    "Calm Introduction Workshop")
    PE_CONFIG=stage_calmhow.sh
    PC_CONFIG=stage_calmhow_pc.sh
    ;;
    #"Citrix Desktop on AHV Workshop")
    #PE_CONFIG=stage_citrixhow.sh
    #PC_CONFIG=stage_citrixhow_pc.sh
    #;;
    #"Tech Summit 2018")
    #PE_CONFIG=stage_ts18.sh
    #PC_CONFIG=stage_ts18_pc.sh
    #;;
    *) echo "No one should ever see this. Time to panic.";;
  esac

  stage_clusters
}

# Send configuration scripts to remote clusters and execute Prism Element script
function stage_clusters {
  for MY_LINE in `cat ${CLUSTER_LIST} | grep -v ^#`
  do
    set -f
    array=(${MY_LINE//|/ })
    MY_PE_HOST=${array[0]}
    MY_PE_PASSWORD=${array[1]}

    # Distribute configuration scripts
    echo "Sending configuration script(s) to ${MY_PE_HOST}"
    send_file scripts/${PE_CONFIG}
    if [ ! -z ${PC_CONFIG} ]; then
      send_file scripts/${PC_CONFIG}
    fi
    # Execute that file asynchroneously remotely (script keeps running on CVM in the background)
    echo "Executing configuration script on ${MY_PE_HOST}"
    remote_exec "MY_PE_PASSWORD=${MY_PE_PASSWORD} nohup bash /home/nutanix/${PE_CONFIG} >> config.log 2>&1 &"
  done

  echo "Progress of individual clusters can be monitored by SSHing to the cluster's virtual IP and running 'tail -f /home/nutanix/${PE_CONFIG}'."
  exit
}

# Display script usage
function usage {
  cat << EOF

Interactive Usage:        stage_workshop
Non-interactive Usage:    stage_workshop -f cluster_list_file -w workshop_number

Available Workshops:
1) Calm Introduction Workshop

See README for more information :+1:

EOF
exit
}

# Check if file passed via command line, otherwise prompt for cluster list file
while getopts ":f:w:" opt; do
  case ${opt} in
    f )
    if [ -f ${OPTARG} ]; then
      CLUSTER_LIST=${OPTARG}
    else
      echo "FILE DOES NOT EXIST!"
      usage
    fi
    ;;
    w )
    if [ $(($OPTARG)) -gt 0 ] && [ $(($OPTARG)) -le $((${#WORKSHOPS[@]}-2)) ]; then
      # do something
      WORKSHOP_NUM=${OPTARG}
    else
      echo "INVALID WORKSHOP SELECTION!"
      usage
    fi
    ;;
    \? ) usage;;
  esac
done
shift $((OPTIND -1))

if [ ! -z ${CLUSTER_LIST} ] && [ ! -z ${WORKSHOP_NUM} ]; then
  # If file and workshop selections are valid, begin staging clusters
  set_workshop
elif [ ! -z ${CLUSTER_LIST} ] || [ ! -z ${WORKSHOP_NUM} ]; then
  echo "MISSING ARGUMENTS!"
  usage
else
  # If no command line arguments, start interactive session
  get_file
fi
