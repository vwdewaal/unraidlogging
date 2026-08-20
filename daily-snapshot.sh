#!/bin/bash

ROOT="/mnt/user/system-logs/snapshots/daily"
DATE="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
DIR="$ROOT/$DATE"
LOCKDIR="/tmp/unraid-daily-snapshot.lock"

logs_root_ready()
{
    mdcmd status 2>/dev/null | grep -qx 'mdState=STARTED' || return 1
    grep -qs '[[:space:]]/mnt/user[[:space:]]fuse\.shfs[[:space:]]' /proc/mounts
}

logs_root_ready || exit 0

mkdir -p "$DIR"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

section()
{
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

OUT="$DIR/system.txt"

{
    echo "Tower Daily System Snapshot"
    echo "Generated: $NOW"
    echo "Hostname: $(hostname)"

    section "UNAME"
    uname -a

    section "UPTIME"
    uptime

    section "UNRAID VERSION"
    cat /etc/unraid-version 2>/dev/null

    section "CPU"
    lscpu 2>/dev/null

    section "MEMORY"
    free -h

    section "MEMORY DETAIL"
    cat /proc/meminfo

    section "PCI HARDWARE"
    lspci -nnk

    section "USB HARDWARE"
    lsusb

    section "BLOCK DEVICES"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL

    section "FILESYSTEM SPACE"
    df -hT

    section "MOUNTS"
    mount

    section "KERNEL MODULES"
    lsmod

    section "TEMPERATURES"
    sensors 2>/dev/null

    section "IP ADDRESSES"
    ip address

    section "ROUTES"
    ip route

    section "NETWORK COUNTERS"
    ip -s link

    section "LISTENING PORTS"
    ss -lntup

    section "ARRAY STATUS"
    mdcmd status 2>/dev/null

} > "$OUT" 2>&1

########################################################################
# NETWORK COUNTER SNAPSHOT
########################################################################

ip -s -j link > "$DIR/network.json" 2>/dev/null

cat > "$DIR/docker.txt" <<EOF
Tower Docker Snapshot
Generated: $NOW
EOF

{
    section "CONTAINERS"

    docker ps -a \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'

    section "DOCKER INFO"
    docker info

    section "DOCKER DISK USAGE"
    docker system df -v

    section "DOCKER NETWORKS"
    docker network ls

    section "DOCKER VOLUMES"
    docker volume ls

} >> "$DIR/docker.txt" 2>&1
{
    echo "Tower ZFS Snapshot"
    echo "Generated: $NOW"

    section "ZPOOL STATUS"
    zpool status -v

    section "ZPOOL LIST"
    zpool list -v

    section "ZFS LIST"
    zfs list

    section "ZFS PROPERTIES"
    zfs get -r \
        used,available,referenced,compressratio,compression,mountpoint \
        2>/dev/null

} > "$DIR/zfs.txt" 2>&1
mkdir -p "$DIR/smart"

########################################################################
# DYNAMIC ARRAY DISK SMART
########################################################################

SMARTDIR="$DIR/smart"
mkdir -p "$SMARTDIR"

INVENTORY="$DIR/disk-inventory.tsv"

printf "ROLE\tDEVICE\tMODEL\tSERIAL\n" > "$INVENTORY"

MDSTATUS="$(mdcmd status 2>/dev/null)"

echo "$MDSTATUS" |
awk -F= '
    /^rdevName\.[0-9]+=/ {
        slot=$1
        sub(/^rdevName\./,"",slot)

        if ($2 != "")
            print slot "|" $2
    }
' |
sort -t'|' -k1,1n |
while IFS='|' read -r SLOT DEV
do
    DEVICE="/dev/$DEV"

    [ -b "$DEVICE" ] || continue

    INFO="$(smartctl -i -n standby "$DEVICE" 2>/dev/null)"

    MODEL="$(
        echo "$INFO" |
        awk -F: '
            /Device Model:|Model Number:/ {
                sub(/^[ \t]+/,"",$2)
                print $2
                exit
            }'
    )"

    SERIAL="$(
        echo "$INFO" |
        awk -F: '
            /Serial Number:/ {
                sub(/^[ \t]+/,"",$2)
                print $2
                exit
            }'
    )"

    [ -n "$MODEL" ] || MODEL="UNKNOWN"
    [ -n "$SERIAL" ] || SERIAL="UNKNOWN-$DEV"

if [ "$SLOT" -eq 0 ]; then
    ROLE="parity"
else
    ROLE="disk$SLOT"
fi
    SAFE_SERIAL="$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_')"

    printf "%s\t%s\t%s\t%s\n" \
        "$ROLE" "$DEVICE" "$MODEL" "$SERIAL" \
        >> "$INVENTORY"

    {
        echo "Role: $ROLE"
        echo "Device: $DEVICE"
        echo "Model: $MODEL"
        echo "Serial: $SERIAL"
        echo "Snapshot: $(date '+%F %T %Z')"
        echo

HISTDIR="/mnt/user/system-logs/history/disks/$SAFE_SERIAL"
mkdir -p "$HISTDIR"

cp "$SMARTDIR/$SAFE_SERIAL.txt" \
   "$HISTDIR/$(date +%F).txt"
        smartctl -a -n standby "$DEVICE"

    } > "$SMARTDIR/$SAFE_SERIAL.txt" 2>&1

done
smartctl -x /dev/sdi \
    > "$DIR/smart/sdi.txt" 2>&1


nvme smart-log /dev/nvme0 \
    > "$DIR/smart/nvme0-smart.txt" 2>&1
# Keep 30 daily snapshots.
find "$ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -mtime +30 \
    -exec rm -rf {} \; 2>/dev/null
