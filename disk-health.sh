#!/bin/bash

LOGROOT="/mnt/user/system-logs/snapshots/disks"
DATE="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
LOGFILE="$LOGROOT/$DATE.log"

logs_root_ready()
{
    mdcmd status 2>/dev/null | grep -qx 'mdState=STARTED' || return 1
    grep -qs '[[:space:]]/mnt/user[[:space:]]fuse\.shfs[[:space:]]' /proc/mounts
}

array_device_map()
{
    mdcmd status 2>/dev/null |
    awk -F= '
        /^rdevName\.[0-9]+=/ {
            slot=$1
            sub(/^rdevName\./,"",slot)
            if ($2 != "") print slot "|" $2
        }
    ' |
    sort -t'|' -k1,1n
}

role_for_slot()
{
    if [ "$1" -eq 0 ]; then
        printf 'parity'
    else
        printf 'disk%s' "$1"
    fi
}

is_array_device()
{
    array_device_map | awk -F'|' -v device="$1" '$2 == device { found=1 } END { exit !found }'
}

non_array_ssd_devices()
{
    while read -r NAME TYPE ROTA
    do
        [ "$TYPE" = "disk" ] || continue
        [ "$ROTA" = "0" ] || continue

        case "$NAME" in
            nvme*) continue ;;
        esac

        is_array_device "$NAME" && continue
        printf '%s\n' "$NAME"
    done < <(lsblk -dn -o NAME,TYPE,ROTA 2>/dev/null)
}

logs_root_ready || exit 0

mkdir -p "$LOGROOT"

{
    echo
    echo "======================================================================"
    echo "DISK HEALTH"
    echo "Time: $NOW"
    echo "======================================================================"

    echo
    echo "### ARRAY HDD SMART SUMMARY ###########################################"

    while IFS='|' read -r SLOT DEV
    do
        [ -b "/dev/$DEV" ] || continue
        ROLE="$(role_for_slot "$SLOT")"

        echo
        echo "---- $ROLE (/dev/$DEV) ------------------------------------------------"
        echo "======================================================================"

        # -n standby prevents waking a sleeping disk.
        smartctl -n standby -H -A -i "/dev/$DEV" 2>&1
    done < <(array_device_map)

    echo
    echo "### NON-ARRAY SATA SSD ################################################"

    while read -r DEV
    do
        [ -b "/dev/$DEV" ] || continue

        echo
        echo "---- /dev/$DEV --------------------------------------------------------"
        echo "======================================================================"
        smartctl -H -A -i "/dev/$DEV" 2>&1
    done < <(non_array_ssd_devices)

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

    while IFS='|' read -r SLOT DEV
    do
        if [ -r "/sys/block/$DEV/stat" ]; then
            printf "%-8s %-12s " "$(role_for_slot "$SLOT")" "/dev/$DEV"
            cat "/sys/block/$DEV/stat"
        fi
    done < <(array_device_map)

    while read -r DEV
    do
        if [ -r "/sys/block/$DEV/stat" ]; then
            printf "%-8s %-12s " "ssd" "/dev/$DEV"
            cat "/sys/block/$DEV/stat"
        fi
    done < <(non_array_ssd_devices)

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
