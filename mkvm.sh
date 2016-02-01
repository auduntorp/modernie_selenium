#!/usr/bin/env bash

# Debug
#set -x
#set -e

cd $(dirname $0)
source config.sh
source functions.sh

# Basic-Checks.
if [ "${1}" == "--help" ] || [ -z "${2}" ] ; then
  echo "Usage:"
  echo " $0 path_to_ova [--delete <VM-Name/UID>] <hub-host> [<port>]"
  exit 0
fi

if [ -z "${1}" ]; then
  echo "Appliance-Path is missing..."
  exit 1
fi

if [ ! -f "${1}" ]; then
  echo "Appliance ${1} not found..."
  exit 1
fi

if [ ! $(which VBoxManage) ]; then
  echo "VBoxManage not found..."
  exit 1
fi

if [ "${USER}" != "${vbox_user}" ]; then
  echo "This script must be run by user \'${vbox_user}\'..."
  exit 1
fi

appliance=${1}
hub_host=${2}
selenium_port=${3}

if [ "${hub_host}" = "--delete" ]; then
  remove_vm=$3
  hub_host=$4
  selenium_port=$5
fi

if [ -z "${selenium_port}" ]
then
    selenium_port=5555
fi

# Check if --delete was given as second parameter to this script. The VM-Name is expected to be the third parameter.
# If no VM-Name is given --delete will be ignored.
if [ "${2}" = "--delete" ]; then
  if [ ! -z "${3}" ]; then
    delete_vm
  else
    log "Delete VM"
    echo "--delete was given, but no VM, aborting..."
    exit 1
  fi
fi

get_vm_info
import_vm
create_temp_path
set_rdp_config
disable_uac
start_vm
activate_vm
shutdown_vm
set_host_only_network
start_vm
disable_firewall
rename_vm
set_ie_config
configure_clipboard
install_java
install_firefox
install_chrome
install_selenium

if [ "${create_snapshot}" = "True" ]; then
  snapshot_vm "Selenium"
  waiting 90
fi

start_vm
sendmessage
