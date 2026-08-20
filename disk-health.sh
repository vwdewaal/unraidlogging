#!/bin/bash

LOGROOT="/mnt/user/system-logs/snapshots/disks"
DATE="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
LOGFILE="$LOGROOT/$DATE.log"

mkdir -p "$LOGROOT"

{
    echo
    echo "======================================================================"
    echo "DISK HEALTH"
    echo "Time: $NOW"
    echo "======================================================================"

    echo
    echo "### ARRAY HDD SMART SUMMARY ###########################################"

    for DEV in sdc sdd sde sdf sdg sdh sdj
    do
        echo
        echo "---- /dev/$DEV --------------------------------------------------------"
        echo "======================================================================"


        # -n standby prevents waking a sleeping disk.
        smartctl -n standby -H -A -i "/dev/$DEV" 2>&1
    done

    echo
    echo "### SATA SSD ##########################################################"

    smartctl -H -A -i /dev/sdi 2>&1

    echo
    echo "### NVME ##############################################################"

    nvme smart-log /dev/nvme0 2>&1

    echo
    echo "### ZFS POOL STATUS ###################################################"

    zpool status -v 2>&1

    echo
    echo "### ZFS POOL LIST #####################################################"

    zpool list 2>&1

    echo
    echo "### BLOCK DEVICE ERROR COUNTERS #######################################"

    for DEV in sdc sdd sde sdf sdg sdh sdj sdi
    do
        if [ -r "/sys/block/$DEV/stat" ]; then
            printf "%-8s " "$DEV"
            cat "/sys/block/$DEV/stat"
        fi
    done

    echo
    echo "### NVME ERROR LOG ####################################################"

    nvme smart-log /dev/nvme0 2>&1 | head -n 100

    echo
    echo "### END ###############################################################"

} >> "$LOGFILE" 2>&1

# Keep 90 days.
find "$LOGROOT" \
    -type f \
    -name '*.log' \
    -mtime +90 \
    -delete 2>/dev/null
