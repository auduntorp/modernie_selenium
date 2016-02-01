#!/usr/bin/env bash
source config.sh
source functions.sh

if [ "$#" -eq "3" ]; then
    selenium_port=${3}
elif [ -z "${2}" ] || [ "${1}" == "--help" ]; then
    echo "Usage: $(basename $0) <path_to_ova> <hub_host> [<port>]"
    exit 1
fi

if [ -z "${selenium_port}" ]
then
    selenium_port=5555
fi

appliance=${1}
hub_host=${2}

vm_temp='D:\'
mkdir temp

get_vm_info
suggested_name_prefix=${vm_name%_*}
vms=$(VBoxManage list vms | awk -F '"' '{print $2}' | grep "${suggested_name_prefix}")
for vm_name in "${vms}"; do
    execute_os_specific config_selenium
    restart_vm
done