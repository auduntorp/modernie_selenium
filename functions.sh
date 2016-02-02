#!/usr/bin/env bash


vm_name=False
vm_pretty_name=False
fatal=False
error=False
warning=False
retry_count=2

copyto() {
  # $1 = filename, $2 = source directory, $3 destination directory
  TARGET=$(realpath ${2}${1})
  if [ ! -f "$TARGET" ]
  then
    echo "Local file '${TARGET}' doesn't exist"
  fi
  execute cp "$TARGET" temp/
  if [ "${3}" != "${vm_temp}" ]
  then
    run_in_vm copy "${vm_temp}${1}" "${3}"
  fi
}

run_in_vm() {
    execute VBoxManage guestcontrol "${vm_name}" --username 'IEUser' --password 'Passw0rd!' run 'C:\Windows\System32\cmd.exe' /C "$@"
}

# Loop VBoxManage guestcontrol commands as they are unreliable.
execute() {
  counter=0
  while [ $counter -lt ${retry_count} ]; do
    echo "Running $@"
    "$@"
    if [ "$?" == "0" ]; then
      guestcontrol_error=0
      break
    else
      guestcontrol_error=1
    fi
    let counter=counter+1
    waiting 10
  done

  if [ "$guestcontrol_error" = "0" ]; then
    return 0
  else
    chk skip 1 "Error running $@"
  fi
}

# Write Logfile and STDOUT.
log() {
  echo ${1} | tee -a "${log_path}${vm_pretty_name}.log"
}

# Error-Handling.
chk() {
  if [ "${2}" != "0" ]; then
    if [ "${1}" = "fatal" ]; then
      log "[FATAL] ${3}"
      fatal=True
      sendmessage
      exit ${2}
    fi
    if [ "${1}" = "skip" ]; then
      log "[WARNING] ${3}"
      warning=True
    fi
    if [ "${1}" = "error" ]; then
      log "[ERROR] ${3}"
      error=True
    fi
  else
    log "[OK]"
  fi
}

# Send Status-Mail.
sendmessage() {
  if [ ! -z ${mailto} ]; then
    subject_prefix="SUCCESS"
    if [ "${warning}" = "True" ]; then
      subject_prefix="WARNING"
    fi
    if [ "${error}" = "True" ]; then
      subject_prefix="ERROR"
    fi
    if [ -f "${log_path}False.log" ]; then
       cat "${log_path}False.log" "${log_path}${vm_pretty_name}.log" > /tmp/${vm_pretty_name}.log
       cat "/tmp/${vm_pretty_name}.log" | mail -s "${subject_prefix}: ${vm_name}" ${mailto}
       rm "${log_path}${vm_pretty_name}.log"
       rm "${log_path}False.log"
    else
       cat "${log_path}${vm_pretty_name}.log" | mail -s "${subject_prefix}: ${vm_name}" ${mailto}
       rm "${log_path}${vm_pretty_name}.log"
    fi
  fi
}

# Get VM OS-Type.
execute_os_specific() {
  case "${vm_os_type}" in
    WindowsXP)
      ${1}_xp
    ;;
    WindowsVista)
      ${1}_wv
    ;;
    Windows7)
      ${1}_w7
    ;;
    Windows8*)
      ${1}_w8
    ;;
    *)
      chk skip 1 "Unexpected OS-Type, skipping ${1}..."
    ;;
  esac
}

# Check if the VM is still running.
check_shutdown() {
  counter=0
  echo -n "Waiting for shutdown"
  while $(VBoxManage showvminfo "${vm_name}" | grep -q 'running'); do
    echo -n "."
    sleep 1
    let counter=counter+1
    if [ ${counter} -ge 120 ]; then
      chk skip 1 "Unable to shutdown/restart..."
      break
    fi
  done
  echo ""
  waiting 5
}

# Print some dots.
waiting() {
  counter=0
  echo -n "Waiting ${1} seconds press any key to continue right away"
  while [ ${counter} -lt ${1} ]; do
    let counter=counter+1
    if read -s -r -p "." -t 1 -n 1; then
        break
    fi
  done
  echo ""
}

set_vm_ie() {
    vm_ie=$(echo "${vm_name}" | awk -F' -' '{print $1}')
    ie_version=${vm_ie:2}
}

# Get informations about the given Appliance (Name, OS-Type, IE-Version)
get_vm_info() {
  vm_info=$(VBoxManage import "${appliance}" -n)
  chk fatal $? "Error getting Appliance Info"

  vm_name=$(echo "${vm_info}" | grep "Suggested VM name" | awk -F'"' '{print $2}')
  vm_pretty_name=$(echo "${vm_info}" | grep "Suggested VM name" | awk -F'"' '{print $2}' | sed 's/_/-/g' | sed 's/ //g' | sed 's/\.//g')
  vm_os_type=$(echo "${vm_info}" | grep 'Suggested OS type' | awk -F'"' '{print $2}')
  set_vm_ie
}

#Internal: Helper-Functions to install the Appliance (called by import_vm)
ex_import_vm_xp() {
  VBoxManage import "${appliance}" --vsys 0 --memory ${vm_mem_xp}
  chk fatal $? "Could not import VM"
}

ex_import_vm_w7() {
  VBoxManage import "${appliance}" --vsys 0 --memory ${vm_mem}
  chk fatal $? "Could not import VM"
}

ex_import_vm_wv() {
  ex_import_vm_w7
}

ex_import_vm_w8() {
  ex_import_vm_w7
}

# Import the given Appliance-File; OS-Specific
import_vm() {
  log "Importing ${appliance} as ${vm_name}..."
  execute_os_specific ex_import_vm
}

set_host_only_network() {
  log "Setting network to host only..."
  execute VBoxManage modifyvm "${vm_name}" --nic2 hostonly --hostonlyadapter2 vboxnet0
  chk error $? "Could not set network to host only"
  if [ ! -z "${selenium_port}" ]; then
    log "Forwarding tcp port ${selenium_port} to host..."
    execute VBoxManage modifyvm "${vm_name}" --natpf1 "tcp-port${selenium_port},tcp,,${selenium_port},,${selenium_port}"
  fi
}

# Find and set free Port for RDP-Connection.
set_rdp_config() {
  log "Setting VRDE-Port ${vrdeport}..."
  vrdeports=$(find "${vm_path}" -name *.vbox -print0 | xargs -0 grep "TCP/Ports" | awk -F'"' '{print $4}' | sort)
  for ((i=9000;i<=10000;i++)); do
    echo ${vrdeports} | grep -q ${i}
    if [[ $? -ne 0 ]]; then
      vrdeport=$i
      break
    fi
  done

  if [ -z "${vrdeport}" ]; then
    vrdeport="9000"
  fi
  if [[ ${vrdeport} < 9000 ]]; then
    vrdeport="9000"
  fi
  if [ "${vrdeport}" = "10000" ]; then
    chk skip $? "Could not find free VRDE-Port"
  else
    execute VBoxManage modifyvm "${vm_name}" --vrde on --vrdeport "${vrdeport}"
    chk error $? "Could not set VRDE-Port"
  fi
}

# Internal: Helper-Functions to disable UAC (called by disable_uac)
ex_disable_uac_w7() {
  log "Mounting Disk..."
  VBoxManage storageattach "${vm_name}" --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium "${tools_path}${deuac_iso}"
  chk fatal $? "Could not mount ${tools_path}${deuac_iso}"
  log "Disabling UAC..."
  VBoxManage startvm "${vm_name}" --type headless
  chk fatal $? "Could not start VM to disable UAC"
  waiting 60
  check_shutdown
  log "Removing Disk..."
  VBoxManage storageattach "${vm_name}" --storagectl "IDE" --port 1 --device 0 --type dvddrive --medium none
  chk fatal $? "Could not unmount ${deuac_iso}"
}

ex_disable_uac_wv() {
  ex_disable_uac_w7
}

ex_disable_uac_w8() {
  ex_disable_uac_w7
}

ex_disable_uac_xp() {
  return 1
}

# Disable UAC; Required to install Java successfully later; OS-Specific
disable_uac() {
  execute_os_specific ex_disable_uac
}

# Start the VM; Wait some seconds afterwards to give the VM time to start up completely.
start_vm() {
  log "Starting VM ${vm_name}..."
  VBoxManage startvm "${vm_name}" --type headless
  chk fatal $? "Could not start VM"
  waiting 60
}

ex_open_firewall_xp() {
  log "Disabling Windows XP Firewall..."
  run_in_vm 'C:\windows\system32\netsh.exe' firewall add portopening TCP ${selenium_port} "Open Port ${selenium_port}"
  chk error $? "Could not disable Firewall"
}

ex_open_firewall_w7() {
  log "Disabling Windows Firewall..."
  run_in_vm 'C:/windows/system32/netsh.exe' advfirewall firewall add rule name="Open Port ${selenium_port}" dir=in action=allow protocol=TCP localport=${selenium_port}
  chk error $? "Could not disable Firewall"
}

ex_open_firewall_wv() {
  ex_open_firewall_w7
}

ex_open_firewall_w8() {
  ex_open_firewall_w7
}

open_firewall() {
  execute_os_specific ex_open_firewall
}

# Create C:\Temp\; Most Functions who copy files to the VM are relying on this folder and will fail is he doesn't exists.
create_temp_path() {
  vm_temp='D:\'
  mkdir temp
  log "Creating folder temp and mounting it as ${vm_temp}..."
  execute VBoxManage sharedfolder add "${vm_name}" --automount --name temp --readonly --hostpath "$(pwd)/temp"
  chk fatal $? "Could not create ${vm_temp}"
}

# Apply registry changes to configure Internet Explorer settings (Protected-Mode, Cache)
set_ie_config() {
  log "Apply IE Protected-Mode Settings..."
  copyto "${ie_protectedmode_reg}" "$tools_path" "$vm_temp"
  run_in_vm 'C:\Windows\Regedit.exe' /s "${vm_temp}ie_protectedmode.reg"
  chk error $? "Could not apply IE Protected-Mode-Settings"
  log "Disabling IE-Cache..."
  copyto ie_disablecache.reg "${tools_path}" "${vm_temp}"
  run_in_vm 'C:\Windows\Regedit.exe' /s "${vm_temp}ie_disablecache.reg"
  chk error $? "Could not disable IE-Cache"
}

# Install Java (required by Selenium); We don't use --wait-exit as it may cause trouble with XP-VMs, instead we just wait some time to ensure the Java-Installer can finish.
install_java() {
  log "Installing Java..."
  copyto "${java_exe}" "${tools_path}" "${vm_temp}"
  run_in_vm "${vm_temp}${java_exe}" /s
  chk error $? "Could not install Java"
  waiting 30
}

# Install Firefox.
install_firefox() {
  log "Installing Firefox..."
  copyto "${firefox_exe}" "${tools_path}" "${vm_temp}"
  run_in_vm "${vm_temp}${firefox_exe}" /S
  chk error $? "Could not install Firefox"
  waiting 10
}

# Install Chrome-Driver for Selenium
install_chrome_driver() {
  log "Installing Chrome Driver..."
  copyto chromedriver.exe "${selenium_path}" 'C:\Windows\system32\\'
  chk error $? "Could not install Chrome Driver"
  waiting 5
}

# Install Chrome.
install_chrome() {
  log "Installing Chrome..."
  copyto "${chrome_exe}" "${tools_path}" "${vm_temp}"
  run_in_vm 'C:\Windows\System32\msiexec.exe' /qn /i "${vm_temp}${chrome_exe}"
  chk error $? "Could not install Chrome"
  waiting 10
  install_chrome_driver
}

# Internal: Helper-Functions to Install Selenium (called by install_selenium)
start_selenium_xp() {
  copyto selenium.bat "${selenium_path}" 'C:\Documents and Settings\All Users\Start Menu\Programs\Startup\'
  chk error $? "Could not copy Selenium-Startup-File"
}

start_selenium_w7() {
  copyto selenium.bat "${selenium_path}" 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\'
  chk error $? "Could not copy Selenium-Startup-File"
}

start_selenium_wv() {
  start_selenium_w7
}

start_selenium_w8() {
  start_selenium_w7
}

create_selenium_config() {
  remote_host=$(VBoxManage guestproperty get "${vm_name}" "/VirtualBox/GuestInfo/Net/0/V4/IP" | awk '{print $2}')
  echo '{' \
       '    "configuration": {' \
       '        "port": '${selenium_port}',' \
       '        "register": true,' \
       '        "registerCycle": 5000,' \
       '        "hubPort": 4444,' \
       '        "hubHost": "'${hub_host}'",' \
       '        "remoteHost": "http://'${remote_host}':'${selenium_port}'"' \
       '    },' \
       '    "capabilities": [' \
       '        {' \
       '            "platform": "'${platform}'",' \
       '            "browserName": "internet explorer",' \
       '            "version": '${ie_version}',' \
       '            "maxInstances": 1,' \
       '            "seleniumProtocol": "WebDriver"' \
       '        }' \
       '    ]' \
       '}' \
       > temp/config.json
}
copy_selenium_config() {
  create_selenium_config
  copyto config.json temp/ 'C:\selenium\'
  chk error $? "Could not copy Selenium-Config"
}

config_selenium_xp() {
  platform="XP"
  copy_selenium_config
}

config_selenium_w7() {
  platform="WINDOWS"
  copy_selenium_config
}

config_selenium_wv() {
  platform="VISTA"
  copy_selenium_config
}

config_selenium_w8() {
  platform="WIN8"
  copy_selenium_config
}

ie11_driver_reg() {
  if [ "${vm_ie}" = "IE11" ]; then
    log "Copy ie11_win32.reg..."
    copyto ie11_win32.reg "${tools_path}" "${vm_temp}"
    chk skip $? "Could not copy ie11_win32.reg"
    log "Setting ie11_win32.reg..."
    run_in_vm 'C:\Windows\Regedit.exe' /s "${vm_temp}ie11_win32.reg"
    chk skip $? "Could not set ie11_win32.reg"
  fi
}

# Install Selenium
install_selenium() {
  log "Creating C:\selenium\..."
  execute VBoxManage guestcontrol "${vm_name}" --username 'IEUser' --password 'Passw0rd!' createdirectory 'C:\selenium\'
  chk fatal $? "Could not create C:\Selenium\\"
  log "Installing Selenium..."
  copyto "${selenium_jar}" "${selenium_path}" 'C:\selenium\'
  chk error $? "Could not install Selenium"
  log "Installing IEDriverServer..."
  copyto IEDriverServer.exe "${selenium_path}" 'C:\Windows\system32\'
  chk error $? "Could not install IEDriverServer.exe"
  log "Configure Selenium..."
  execute_os_specific config_selenium
  log "Prepare Selenium-Autostart..."
  execute_os_specific start_selenium
  ie11_driver_reg
}

# Create a Snapshot; Disabled by default.
snapshot_vm() {
  log "Creating Snapshot ${1}..."
  VBoxManage snapshot "${vm_name}" take "${1}"
  chk skip $? "Could not create Snapshot ${1}"
}

# Reboot the VM; Ensure to wait some time after sending the reboot-Command so that the machine can start up before other actions will applied.
# shutdown.exe is used because VBox ACPI-Functions are sometimes unreliable with XP-VMs.
reboot_vm() {
  log "Rebooting..."
  run_in_vm 'C:\Windows\system32\shutdown.exe' /t 5 /r /f
  chk skip $? "Could not reboot"
  waiting 90
}

# Shutdown the VM and control the success via showvminfo; shutdown.exe is used because VBox ACPI-Functions are sometimes unreliable with XP-VMs.
shutdown_vm() {
  log "Shutting down..."
  run_in_vm 'C:\Windows\system32\shutdown.exe' /t 5 /s /f
  chk skip $? "Could not shut down"
  check_shutdown
}

shutdown_vm_for_removal() {
  log "Shutting down for removal..."
  execute VBoxManage guestcontrol "${remove_vm}" --username 'IEUser' --password 'Passw0rd!' run 'C:\Windows\system32\shutdown.exe' /t 5 /s /f
  chk skip $? "Could not shut down for removal"
}

# Remove the given Machine from VBox and delete all associated files. Shut down the VM beforehand, if needed.
delete_vm() {
  log "Removing ${remove_vm}..."
  if [ ! $(VBoxManage showvminfo "${remove_vm}" | grep -q 'running') ]; then
    shutdown_vm_for_removal
    waiting 30
  fi
  execute VBoxManage unregistervm "${remove_vm}" --delete
  chk skip $? "Could not remove VM ${remove_vm}"
  waiting 10
}

# Change the Hostname of the VM; Avoids duplicate Names on the Network in case you set up several instances of the same Appliance.
# We copy the rename.bat because the VBox exec doesn't provide the needed Parameters in a way wmic.exe is able to apply correctly.
# Also WinXP usually fails to set the name, you can use C:\Temp\rename.bat to set it manually on the VM. Make sure to restart afterwards.
rename_vm() {
  case ${vm_name} in
    IE6*WinXP*)
      vm_orig_name="ie6winxp"
    ;;
    IE8*WinXP*)
      vm_orig_name="ie8winxp"
    ;;
    IE7*Vista*)
      vm_orig_name="IE7Vista"
    ;;
    IE8*Win7*)
      vm_orig_name="IE8Win7"
    ;;
    IE9*Win7*)
      vm_orig_name="IE9Win7"
    ;;
    IE10*Win7*)
      vm_orig_name="IE10Win7"
    ;;
    IE11*Win7*)
      vm_orig_name="IE11Win7"
    ;;
    IE10*Win8*)
      vm_orig_name="IE10Win8"
    ;;
    IE11*Win8*)
      vm_orig_name="IE11Win8_1"
    ;;
    *)
      chk skip 1 "Could not find hostname, skip renaming..."
      return 1
    ;;
  esac
  log "Preparing to change Hostname ${vm_orig_name} to ${vm_pretty_name}..."
  echo 'c:\windows\system32\wbem\wmic.exe computersystem where caption="'${vm_orig_name}'" call rename "'${vm_pretty_name}'"' > /tmp/rename.bat
  chk skip $? "Could not create rename.bat"
  log "Copy rename.bat..."
  copyto rename.bat '/tmp/' "${vm_temp}"
  chk skip $? "Could not copy rename.bat"
  log "Launch rename.bat..."
  run_in_vm "${vm_temp}rename.bat"
  chk skip $? "Could not change Hostname"
  waiting 5
}

configure_clipboard() {
  log "Changing Clipboard-Mode to bidirectional..."
  VBoxManage controlvm "${vm_name}" clipboard bidirectional
  chk skip $? "Could not set Clipboard-Mode"
  waiting 5
}

ex_activate_vm_xp() {
  chk skip 0 "Nothing to do..."
}

ex_activate_vm_w7() {
  run_in_vm start /b slmgr /ato
  chk skip $? "Could not activate Windows"
  waiting 15
}

ex_activate_vm_wv() {
  ex_activate_vm_w7
}

ex_activate_vm_w8() {
  ex_activate_vm_w7
}

activate_vm() {
  execute_os_specific ex_activate_vm
}

set_date_in_future() {
  execute VBoxManage modifyvm "${vm_name}" --biossystemtimeoffset +36000000000
}

set_date_back() {
  execute VBoxManage modifyvm "${vm_name}" --biossystemtimeoffset -36000000000
}
