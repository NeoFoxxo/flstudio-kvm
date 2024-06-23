#!/usr/bin/env bash

###
## libvirt qemu hooks for virtual DAW. Check this reddit post for more information:
## https://www.reddit.com/r/VFIO/comments/pckwz1/guideline_virtual_daw_linux_host_windows_guest/
##
## Licensed under WTFPL (http://www.wtfpl.net/)
## FIRST INSTALL HOOK HELPER: (https://passthroughpo.st/simple-per-vm-libvirt-hooks-with-the-vfio-tools-hook-helper/)
## THEN STORE IN: /etc/libvirt/hooks/qemu.d/
###

## Change the following variables to fit your configuration.
logfile="/var/log/libvirt-hook.log"

# Set this to the name of your VM
my_guest_name="windows10"

# Guest RAM to reserve exclusively (in GiB)
guest_ram_gb=8

# Cores to isolate (shield), zero-indexed
cores_to_shield="0,1,2,9,10,11"

# The total hugepage scaling factor in percent (should usually be between 102-105% of the actual guest memory)
hugepage_scale_factor=105

# Don't change anything down from here
all_cores="0-$[$(nproc)-1]"
guest_name=$1
mode=$2
level=$3
slice_name="$(echo "$my_guest_name" | tr '[:upper:]' '[:lower:]')"

# Redirect all the output of the script to the log file.
exec &>> ${logfile}

# Calculates the hugepage size required to start the VM by inspecting the guest settings.
get_hugepage_size() {
	vmid=$1
	
#   TODO: Autodetection does not work because virsh is not available in hook scripts.
#	ram_in_kb=$(virsh dumpxml $vmid | grep currentMemory | grep -o -E '[0-9]+')
#	guest_ram_gb=$[ram_in_kb / 1024 / 1024]

	guest_ram=$[(guest_ram_gb * 1024)/2] # Calculate byte size
	guest_ram=$[(guest_ram * 102) / 100] # Apply extra

	echo $guest_ram
}

shield_vm() {
	echo "Shielding VM ..."

	echo 3F > /sys/bus/workqueue/devices/writeback/cpumask

	systemctl set-property --runtime -- user.slice AllowedCPUs=$cores_to_shield
	systemctl set-property --runtime -- system.slice AllowedCPUs=${cores_to_shield}
	systemctl set-property --runtime -- init.scope AllowedCPUs=${cores_to_shield}
}

unshield_vm() {
	echo "Unshielding VM ..."

	echo "${unshielded_cores}" > /sys/fs/cgroup/cpuset/machine.slice/cpuset.cpus

    echo FFF > /sys/bus/workqueue/devices/writeback/cpumask

 systemctl set-property --runtime -- user.slice AllowedCPUs=0-11
 systemctl set-property --runtime -- system.slice AllowedCPUs=0-11
 systemctl set-property --runtime -- init.scope AllowedCPUs=0-11
}

echo "Hook $mode ($level) was called for machine $guest_name."

if [ "$guest_name" != "$my_guest_name" ]; then
	echo "Ignoring hooks for $guest_name."
	exit
fi

if [ "$mode" = "diag" ]; then
	echo "Diagnostics for VM $guest_name"

	echo "Guest RAM: ${guest_ram_gb} GiB"
	echo "Calculated hugepage size: $(get_hugepage_size $guest_name)"
fi

if [ "$mode" = "stopped" ]; then
	echo "Stopped."

	# Reset hugepages
	echo "Disabling hugepages ..."
	sysctl vm.nr_hugepages=0

	# Reset frequency scaling.
	echo "Restoring default CPU frequency scaling."
	cpupower frequency-set -g powersave

	# Reset all of those other weird stuff.
	echo "Restoring system stuff."
	
	sysctl vm.stat_interval=1
    sysctl -w kernel.watchdog=1

	# echo always > /sys/kernel/mm/transparent_hugepage/enabled
	# echo 1 > /sys/bus/workqueue/devices/writeback/numa

	# Finally unshield the cores.
	echo "Unshielding cores."
	unshield_vm
fi

if [ "$mode" = "prepare" ]; then
	echo "Setting up system stuff."
	

	# I wish I knew what all this stuff does. On second thought I don't.
	echo 3 > /proc/sys/vm/drop_caches
	echo 1 > /proc/sys/vm/compact_memory
	
	sysctl vm.stat_interval=120
	sysctl -w kernel.watchdog=0

	# echo never > /sys/kernel/mm/transparent_hugepage/enabled
	# echo 0 > /sys/bus/workqueue/devices/writeback/numa

	# Disable frequency scaling for the shielded cores.
	echo "Enabling performance mode for guest cores."
	cpupower frequency-set -g performance

	# Shield the cores.
	echo "Shielding cores."
	shield_vm

	# Adjust the hugepage size.
	echo "Enabling hugepages."
    nr_hugepages=$(get_hugepage_size $guest_name)
	echo "Calculated hugepage count: $nr_hugepages"

	sysctl vm.nr_hugepages=$nr_hugepages
fi

# if [ "$mode" == "release" ]; then
# 		# This makes pulse redetect the device.
# 		pacmd unload-module module-udev-detect && pacmd load-module module-udev-detect
# 	fi
# fi

echo "Hook '$mode' completed."
