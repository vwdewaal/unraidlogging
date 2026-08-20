#!/bin/bash

LOGROOT="/mnt/user/system-logs/blackbox"
DATE="$(date '+%Y-%m-%d')"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
HOST="$(hostname)"
LOGFILE="$LOGROOT/$DATE.log"
LOCKDIR="/tmp/unraid-blackbox.lock"

logs_root_ready()
{
    mdcmd status 2>/dev/null | grep -qx 'mdState=STARTED' || return 1
    grep -qs '[[:space:]]/mnt/user[[:space:]]fuse\.shfs[[:space:]]' /proc/mounts
}

logs_root_ready || exit 0

mkdir -p "$LOGROOT"

# Prevent overlapping runs.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi

trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

{
    echo
    echo "======================================================================"
    echo "BLACKBOX"
    echo "Host: $HOST"
    echo "Time: $NOW"
    echo "======================================================================"

    echo
    echo "### UPTIME / LOAD #####################################################"
    uptime

    echo
    echo "### MEMORY ############################################################"
    free -h

    echo
    echo "### VMSTAT ############################################################"
    vmstat 1 2

    echo
    echo "### CPU ###############################################################"
    mpstat -P ALL 1 1 2>/dev/null

    echo
    echo "### FILESYSTEMS #######################################################"
    df -hT

    echo
    echo "### TEMPERATURES ######################################################"
    sensors 2>/dev/null

    echo
    echo "### TOP CPU PROCESSES #################################################"
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,etime,comm,args \
       --sort=-%cpu | head -n 21

    echo
    echo "### TOP MEMORY PROCESSES ##############################################"
    ps -eo pid,ppid,user,stat,%cpu,%mem,rss,vsz,etime,comm,args \
       --sort=-%mem | head -n 21

    echo
    echo "### DISK IO ###########################################################"
    iostat -xz 1 2 2>/dev/null

    echo
    echo "### NETWORK INTERFACES ################################################"
    ip -br address 2>/dev/null

    echo
    echo "### NETWORK COUNTERS ##################################################"
    ip -s link 2>/dev/null

    echo
    echo "### ROUTING ###########################################################"
    ip route 2>/dev/null

    echo
    echo "### CONNECTION SUMMARY ################################################"
    ss -s 2>/dev/null

    echo
    echo "### LISTENING PORTS ###################################################"
    ss -lntup 2>/dev/null

    echo
    echo "### DOCKER CONTAINERS #################################################"
    docker ps -a \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
        2>/dev/null

    echo
    echo "### DOCKER RESOURCE USAGE #############################################"
    docker stats --no-stream \
        --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' \
        2>/dev/null

    echo
    echo "### ZFS POOLS #########################################################"
    zpool status 2>/dev/null

    echo
    echo "### ZFS CAPACITY ######################################################"
    zpool list 2>/dev/null

    echo
    echo "### UNRAID ARRAY ######################################################"
    if command -v mdcmd >/dev/null 2>&1; then
        mdcmd status 2>/dev/null
    else
        echo "mdcmd not available"
    fi

    echo
    echo "### RECENT KERNEL WARNINGS / ERRORS ###################################"
    dmesg --level=emerg,alert,crit,err,warn 2>/dev/null | tail -n 100

    echo
    echo "### END ###############################################################"

} >> "$LOGFILE" 2>&1

# Retain 30 days of black-box logs.
find "$LOGROOT" \
    -type f \
    -name '*.log' \
    -mtime +30 \
    -delete 2>/dev/null
