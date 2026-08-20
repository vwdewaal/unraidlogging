#!/bin/bash

set -u

LOGROOT="/mnt/user/system-logs"
OUTROOT="$LOGROOT/diagnostics"

STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
HOST="$(hostname)"
WORK="$OUTROOT/${HOST}-${STAMP}"
ARCHIVE="$OUTROOT/${HOST}-${STAMP}.tar.gz"

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

smart_snapshot()
{
    ROLE="$1"
    DEVICE="$2"
    INFO="$(smartctl -i -n standby "$DEVICE" 2>&1)"
    SERIAL="$(echo "$INFO" | awk -F: '/Serial Number:/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -n "$SERIAL" ] || SERIAL="unknown"
    SAFE_SERIAL="$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_')"

    {
        echo "Role: $ROLE"
        echo "Device: $DEVICE"
        echo "Serial: $SERIAL"
        echo
        smartctl -n standby -x "$DEVICE"
    } > "$WORK/smart/${ROLE}-${SAFE_SERIAL}.txt" 2>&1
}

if ! logs_root_ready; then
    echo "User-share mount is unavailable; diagnostics were not written."
    exit 0
fi

mkdir -p "$WORK"

echo
echo "============================================================"
echo " UNRAID EXTENDED DIAGNOSTICS"
echo "============================================================"
echo
echo "Host:       $HOST"
echo "Time:       $(date)"
echo "Collecting: $WORK"
echo

########################################################################
# Current system state
########################################################################

echo "[1/9] Current system state..."

{
    echo "Generated: $(date)"
    echo

    echo "===== UPTIME ====="
    uptime

    echo
    echo "===== MEMORY ====="
    free -h

    echo
    echo "===== LOAD ====="
    cat /proc/loadavg

    echo
    echo "===== FILESYSTEMS ====="
    df -hT

    echo
    echo "===== BLOCK DEVICES ====="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

    echo
    echo "===== TEMPERATURES ====="
    sensors 2>/dev/null

    echo
    echo "===== TOP CPU ====="
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,etime,comm,args \
        --sort=-%cpu | head -n 51

    echo
    echo "===== TOP MEMORY ====="
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,etime,comm,args \
        --sort=-%mem | head -n 51

} > "$WORK/current-system.txt" 2>&1


########################################################################
# Kernel
########################################################################

echo "[2/9] Kernel state..."

{
    echo "===== DMESG ====="
    dmesg

    echo
    echo "===== KERNEL MODULES ====="
    lsmod

} > "$WORK/kernel.txt" 2>&1


########################################################################
# Network
########################################################################

echo "[3/9] Network state..."

{
    echo "===== ADDRESSES ====="
    ip address

    echo
    echo "===== ROUTES ====="
    ip route

    echo
    echo "===== LINK COUNTERS ====="
    ip -s link

    echo
    echo "===== CONNECTION SUMMARY ====="
    ss -s

    echo
    echo "===== LISTENING PORTS ====="
    ss -lntup

} > "$WORK/network.txt" 2>&1


########################################################################
# Docker
########################################################################

echo "[4/9] Docker state..."

{
    echo "===== CONTAINERS ====="

    docker ps -a \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'

    echo
    echo "===== RESOURCE USAGE ====="

    docker stats --no-stream

    echo
    echo "===== DOCKER INFO ====="

    docker info

    echo
    echo "===== DISK USAGE ====="

    docker system df

} > "$WORK/docker.txt" 2>&1


########################################################################
# ZFS
########################################################################

echo "[5/9] ZFS state..."

{
    echo "===== ZPOOL STATUS ====="
    zpool status -v

    echo
    echo "===== ZPOOL LIST ====="
    zpool list -v

    echo
    echo "===== ZFS LIST ====="
    zfs list

} > "$WORK/zfs.txt" 2>&1


########################################################################
# SMART / NVMe
########################################################################

echo "[6/9] Storage health..."

mkdir -p "$WORK/smart"

while IFS='|' read -r SLOT DEV
do
    [ -b "/dev/$DEV" ] || continue
    smart_snapshot "$(role_for_slot "$SLOT")" "/dev/$DEV"
done < <(array_device_map)

while read -r DEV
do
    [ -b "/dev/$DEV" ] || continue
    smart_snapshot "ssd" "/dev/$DEV"
done < <(non_array_ssd_devices)

nvme smart-log /dev/nvme0 \
    > "$WORK/smart/nvme0-smart.txt" 2>&1

nvme error-log /dev/nvme0 \
    > "$WORK/smart/nvme0-errors.txt" 2>&1


########################################################################
# Historical logging
########################################################################

echo "[7/9] Historical evidence..."

mkdir -p "$WORK/history"

# Critical events
if [ -f "$LOGROOT/events/critical-events.log" ]; then
    cp "$LOGROOT/events/critical-events.log" \
       "$WORK/history/"
fi

# Today's and yesterday's blackbox logs
for DAYSAGO in 0 1
do
    DAY="$(date -d "$DAYSAGO day ago" '+%Y-%m-%d')"

    if [ -f "$LOGROOT/blackbox/$DAY.log" ]; then
        cp "$LOGROOT/blackbox/$DAY.log" \
           "$WORK/history/blackbox-$DAY.log"
    fi
done

# Recent disk-health logs
if [ -d "$LOGROOT/snapshots/disks" ]; then
    cp -a "$LOGROOT/snapshots/disks" \
          "$WORK/history/disk-health"
fi

# Current persistent syslog
if [ -f "$LOGROOT/syslog-Tower.log" ]; then
    cp "$LOGROOT/syslog-Tower.log" \
       "$WORK/history/"
fi


########################################################################
# Official Unraid diagnostics
########################################################################

echo "[8/9] Official Unraid diagnostics..."

mkdir -p "$WORK/unraid"

BEFORE="$(find /boot/logs -maxdepth 1 -type f \
    -name '*diagnostics*.zip' 2>/dev/null)"

diagnostics >/dev/null 2>&1

AFTER="$(find /boot/logs -maxdepth 1 -type f \
    -name '*diagnostics*.zip' 2>/dev/null)"

NEWFILE="$(comm -13 \
    <(printf '%s\n' "$BEFORE" | sort) \
    <(printf '%s\n' "$AFTER" | sort) \
    | tail -n 1)"

if [ -n "$NEWFILE" ] && [ -f "$NEWFILE" ]; then
    cp "$NEWFILE" "$WORK/unraid/"
else
    echo "Could not identify newly generated Unraid diagnostics ZIP." \
        > "$WORK/unraid/README.txt"
fi


########################################################################
# Create archive
########################################################################

echo "[9/9] Creating archive..."

tar -czf "$ARCHIVE" \
    -C "$OUTROOT" \
    "$(basename "$WORK")"

if [ $? -eq 0 ]; then

    rm -rf "$WORK"

    echo
    echo "============================================================"
    echo " COMPLETE"
    echo "============================================================"
    echo
    echo "Archive:"
    echo
    echo "$ARCHIVE"
    echo

    du -h "$ARCHIVE"

else

    echo
    echo "ERROR: Archive creation failed."
    echo
    echo "Uncompressed diagnostics retained at:"
    echo "$WORK"

    exit 1

fi
