#!/bin/bash

LOGROOT="/mnt/user/system-logs"
TODAY="$(date +%F)"

PASS=0
WARN=0
FAIL=0

pass()
{
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

warn()
{
    echo "[WARN] $1"
    WARN=$((WARN + 1))
}

fail()
{
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

echo
echo "======================================================================"
echo " UNRAID HEALTH SUMMARY"
echo "======================================================================"
echo
echo "Host: $(hostname)"
echo "Time: $(date)"
echo

########################################################################
# UPTIME / LOAD
########################################################################

echo "SYSTEM"
echo "----------------------------------------------------------------------"

UPTIME="$(uptime -p 2>/dev/null)"
echo "Uptime: $UPTIME"

LOAD1="$(awk '{print $1}' /proc/loadavg)"
CPUS="$(nproc)"


awk -v loadval="$LOAD1" -v cpus="$CPUS" \
    'BEGIN { exit !(loadval > cpus * 2) }'

if [ $? -eq 0 ]; then
    warn "1-minute load is high: $LOAD1 across $CPUS CPUs"
else
    pass "System load looks reasonable: $LOAD1 across $CPUS CPUs"
fi

########################################################################
# MEMORY
########################################################################

MEM_TOTAL="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_AVAIL="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

if [ "$MEM_TOTAL" -gt 0 ]; then
    MEM_FREE_PCT=$(( MEM_AVAIL * 100 / MEM_TOTAL ))

    if [ "$MEM_FREE_PCT" -lt 5 ]; then
        fail "Available memory critically low: ${MEM_FREE_PCT}%"
    elif [ "$MEM_FREE_PCT" -lt 15 ]; then
        warn "Available memory low: ${MEM_FREE_PCT}%"
    else
        pass "Available memory: ${MEM_FREE_PCT}%"
    fi
fi

########################################################################
# FILESYSTEM SPACE
########################################################################

echo
echo "FILESYSTEMS"
echo "----------------------------------------------------------------------"


while read -r FS SIZE USED AVAIL PCT MOUNT
do
    NUM="${PCT%\%}"

    case "$NUM" in
        ''|*[!0-9]*) continue ;;
    esac

    # Unassigned Devices / removable mounts
    case "$MOUNT" in
        /mnt/disks/*)
            if [ "$NUM" -ge 95 ]; then
                warn "Unassigned device $MOUNT is ${NUM}% full"
            elif [ "$NUM" -ge 85 ]; then
                warn "Unassigned device $MOUNT is ${NUM}% full"
            fi
            continue
            ;;
    esac

    if [ "$NUM" -ge 95 ]; then
        fail "$MOUNT is ${NUM}% full"
    elif [ "$NUM" -ge 85 ]; then
        warn "$MOUNT is ${NUM}% full"
    fi

done < <(
    df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null |
    tail -n +2
)

########################################################################
# ZFS
########################################################################

echo
echo "ZFS"
echo "----------------------------------------------------------------------"

if command -v zpool >/dev/null 2>&1; then

    ZSTATUS="$(zpool status -x 2>&1)"

    if echo "$ZSTATUS" | grep -qi "all pools are healthy"; then
        pass "All ZFS pools healthy"
    elif echo "$ZSTATUS" | grep -Eqi 'DEGRADED|FAULTED|UNAVAIL|SUSPENDED'; then
        fail "ZFS pool problem detected"
        echo "$ZSTATUS" | sed 's/^/       /'
    else
        warn "ZFS health requires review"
        echo "$ZSTATUS" | sed 's/^/       /'
    fi

else
    warn "zpool command unavailable"
fi

########################################################################
# ARRAY
########################################################################

echo
echo "UNRAID ARRAY"
echo "----------------------------------------------------------------------"

if command -v mdcmd >/dev/null 2>&1; then

    ARRAY="$(mdcmd status 2>/dev/null)"

    if echo "$ARRAY" | grep -q 'mdState=STARTED'; then
        pass "Array is started"
    else
        warn "Array does not report STARTED"
    fi

    ERRORS="$(echo "$ARRAY" |
        awk -F= '/rdevName/ {dev=$2} /rdevNumErrors/ {if ($2+0 > 0) print dev ":" $2}')"

    if [ -n "$ERRORS" ]; then
        fail "Unraid array disk errors detected:"
        echo "$ERRORS" | sed 's/^/       /'
    else
        pass "No Unraid array disk errors reported"
    fi

else
    warn "mdcmd unavailable"
fi

########################################################################
# HDD SMART
########################################################################

echo
echo "HDD SMART"
echo "----------------------------------------------------------------------"

INVENTORY="/mnt/user/system-logs/snapshots/daily/$(date +%F)/disk-inventory.tsv"


if [ ! -f "$INVENTORY" ]; then
    warn "Current disk inventory not found"
else

    while IFS=$'\t' read -r ROLE DEVICE MODEL SERIAL
    do
        [ "$ROLE" = "ROLE" ] && continue
        [ -n "$ROLE" ] || continue
        [ -b "$DEVICE" ] || continue

        RESULT="$(smartctl -n standby -H -A "$DEVICE" 2>&1)"

        if echo "$RESULT" | grep -q "STANDBY"; then
            pass "$ROLE $SERIAL sleeping - not woken for health check"
            continue
        fi

        if echo "$RESULT" |
            grep -qiE 'overall-health.*FAILED|SMART Health Status:.*FAILED'; then

            fail "$ROLE $SERIAL SMART health FAILED"
            continue
        fi

        REALLOC="$(
            echo "$RESULT" |
            awk '/Reallocated_Sector_Ct/ {print $NF; exit}'
        )"

        PENDING="$(
            echo "$RESULT" |
            awk '/Current_Pending_(Sector|ECC_Cnt)/ {print $NF; exit}'
        )"

        UNCORR="$(
            echo "$RESULT" |
            awk '/Offline_Uncorrectable/ {print $NF; exit}'
        )"

        CRC="$(
            echo "$RESULT" |
            awk '/UDMA_CRC_Error_Count/ {print $NF; exit}'
        )"

        ISSUES=0

        for VALUE in "$REALLOC" "$PENDING" "$UNCORR"
        do
            case "$VALUE" in
                ''|*[!0-9]*) ;;
                *)
                    if [ "$VALUE" -gt 0 ]; then
                        ISSUES=1
                    fi
                    ;;
            esac
        done

        if [ "$ISSUES" -eq 1 ]; then
            fail "$ROLE $SERIAL SMART media counters need review (reallocated=${REALLOC:-n/a}, pending=${PENDING:-n/a}, uncorrectable=${UNCORR:-n/a})"
        else
            pass "$ROLE $SERIAL SMART media counters clean"
        fi

        case "$CRC" in
            ''|*[!0-9]*) ;;
            *)
                if [ "$CRC" -gt 0 ]; then
                    warn "$ROLE $SERIAL has $CRC historical UDMA CRC errors"
                fi
                ;;
        esac

    done < "$INVENTORY"
fi
# SATA SSD
########################################################################

echo
echo "SATA SSD"
echo "----------------------------------------------------------------------"

if [ -b /dev/sdi ]; then

    RESULT="$(smartctl -H -A /dev/sdi 2>&1)"

    if echo "$RESULT" | grep -qiE 'overall-health.*FAILED|SMART Health Status:.*FAILED'; then
        fail "/dev/sdi SMART health FAILED"
    else
        pass "/dev/sdi SMART health passed"
    fi

fi

########################################################################
# NVME
########################################################################

echo
echo "NVME"
echo "----------------------------------------------------------------------"

if command -v nvme >/dev/null 2>&1 && [ -e /dev/nvme0 ]; then

    NVME="$(nvme smart-log /dev/nvme0 2>/dev/null)"

    CRITICAL="$(echo "$NVME" | awk -F: '/critical_warning/ {gsub(/ /,"",$2); print $2; exit}')"
    MEDIA="$(echo "$NVME" | awk -F: '/media_errors/ {gsub(/ /,"",$2); print $2; exit}')"
    USED="$(echo "$NVME" | awk -F: '/percentage_used/ {gsub(/[ %]/,"",$2); print $2; exit}')"
    TEMP="$(echo "$NVME" | awk -F: '/^temperature/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    UNSAFE="$(echo "$NVME" | awk -F: '/unsafe_shutdowns/ {gsub(/ /,"",$2); print $2; exit}')"

    if [ "${CRITICAL:-1}" = "0" ]; then
        pass "NVMe critical warning = 0"
    else
        fail "NVMe critical warning = ${CRITICAL:-unknown}"
    fi

    if [ "${MEDIA:-1}" = "0" ]; then
        pass "NVMe media errors = 0"
    else
        fail "NVMe media errors = ${MEDIA:-unknown}"
    fi

    if [ -n "$USED" ]; then
        if [ "$USED" -ge 90 ]; then
            warn "NVMe endurance used: ${USED}%"
        else
            pass "NVMe endurance used: ${USED}%"
        fi
    fi

    echo "       NVMe temperature: ${TEMP:-unknown}"
    echo "       Unsafe shutdowns: ${UNSAFE:-unknown}"

else
    warn "NVMe health information unavailable"
fi

########################################################################
# DOCKER
########################################################################

echo
echo "DOCKER"
echo "----------------------------------------------------------------------"

if command -v docker >/dev/null 2>&1; then

    if docker info >/dev/null 2>&1; then
        pass "Docker daemon responding"

    UNHEALTHY="$(
    docker ps \
        --format '{{.Names}}|{{.Status}}' 2>/dev/null |
    grep -Ei '\(unhealthy\)'
)"

STOPPED="$(
    docker ps -a \
        --filter status=exited \
        --format '{{.Names}}|{{.Status}}' 2>/dev/null
)"

if [ -n "$UNHEALTHY" ]; then
    warn "Running containers are unhealthy:"
    echo "$UNHEALTHY" | sed 's/^/       /'
else
    pass "No running containers are unhealthy"
fi

if [ -n "$STOPPED" ]; then
    echo
    echo "[INFO] Stopped containers:"
    echo "$STOPPED" | sed 's/^/       /'
fi
    else
        fail "Docker daemon not responding"
    fi

else
    warn "Docker unavailable"
fi

########################################################################
# RECENT CRITICAL EVENTS
########################################################################

echo
echo "RECENT EVENTS"
echo "----------------------------------------------------------------------"

EVENTFILE="$LOGROOT/events/critical-events.log"

if [ -f "$EVENTFILE" ]; then

    COUNT="$(tail -n 100 "$EVENTFILE" |
        grep -Eiv 'TEST I/O error event extractor' |
        wc -l)"

    if [ "$COUNT" -gt 0 ]; then
        warn "$COUNT recent critical-event entries exist"

        echo
        tail -n 10 "$EVENTFILE" |
            grep -Eiv 'TEST I/O error event extractor' |
            sed 's/^/       /'
    else
        pass "No real critical events recorded yet"
    fi

else
    pass "No critical event file yet"
fi

########################################################################
# BLACKBOX FRESHNESS
########################################################################

echo
echo "LOGGER HEALTH"
echo "----------------------------------------------------------------------"

BLACKBOX="$LOGROOT/blackbox/$TODAY.log"

if [ -f "$BLACKBOX" ]; then

    AGE=$(( $(date +%s) - $(stat -c %Y "$BLACKBOX") ))

    if [ "$AGE" -le 600 ]; then
        pass "Blackbox logger is current"
    else
        warn "Blackbox log has not updated for $((AGE / 60)) minutes"
    fi

else
    fail "Today's blackbox log does not exist"
fi

DISKLOG="$LOGROOT/snapshots/disks/$TODAY.log"

if [ -f "$DISKLOG" ]; then

    AGE=$(( $(date +%s) - $(stat -c %Y "$DISKLOG") ))

    if [ "$AGE" -le 7200 ]; then
        pass "Disk-health logger is current"
    else
        warn "Disk-health log has not updated for $((AGE / 3600)) hours"
    fi

else
    warn "Today's disk-health log does not exist"
fi

########################################################################
# SUMMARY
########################################################################

echo
echo "======================================================================"
echo " SUMMARY"
echo "======================================================================"
echo
printf "PASS : %d\n" "$PASS"
printf "WARN : %d\n" "$WARN"
printf "FAIL : %d\n" "$FAIL"
echo

if [ "$FAIL" -gt 0 ]; then
    echo "OVERALL STATUS: FAIL"
    EXIT=2
    HEALTH_STATUS="FAIL"
elif [ "$WARN" -gt 0 ]; then
    echo "OVERALL STATUS: WARN"
    EXIT=1
    HEALTH_STATUS="WARN"
else
    echo "OVERALL STATUS: PASS"
    EXIT=0
    HEALTH_STATUS="PASS"
fi

echo

########################################################################
# OPTIONAL SNMP STATE-CHANGE TRAP
########################################################################

# This is deliberately opt-in. Keep credentials in the protected, untracked
# config file on the flash drive, never in this Git repository.
SNMP_CONFIG="/boot/config/system-logging/snmp-trap.conf"
SNMP_STATE="/boot/config/system-logging/.health-trap-state"

send_health_trap()
{
    [ -r "$SNMP_CONFIG" ] || return 0

    if ! command -v snmptrap >/dev/null 2>&1; then
        logger -t unraid-health "SNMP traps enabled but snmptrap is unavailable"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$SNMP_CONFIG"

    : "${SNMP_TRAP_HOST:=}"
    : "${SNMP_TRAP_PORT:=162}"
    : "${SNMP_TRAP_USER:=}"
    : "${SNMP_TRAP_AUTH_PASSWORD:=}"
    : "${SNMP_TRAP_PRIV_PASSWORD:=}"
    : "${SNMP_TRAP_AUTH_PROTOCOL:=SHA}"
    : "${SNMP_TRAP_PRIV_PROTOCOL:=AES}"

    if [ -z "$SNMP_TRAP_HOST" ] || [ -z "$SNMP_TRAP_USER" ] || \
       [ -z "$SNMP_TRAP_AUTH_PASSWORD" ] || [ -z "$SNMP_TRAP_PRIV_PASSWORD" ]; then
        logger -t unraid-health "SNMP trap config is incomplete"
        return 0
    fi

    PREVIOUS_STATUS="$(cat "$SNMP_STATE" 2>/dev/null)"
    [ "$HEALTH_STATUS" = "$PREVIOUS_STATUS" ] && return 0

    SUMMARY="Unraid health changed from ${PREVIOUS_STATUS:-unknown} to $HEALTH_STATUS (pass=$PASS warn=$WARN fail=$FAIL)"

    if snmptrap -v 3 -l authPriv \
        -u "$SNMP_TRAP_USER" \
        -a "$SNMP_TRAP_AUTH_PROTOCOL" -A "$SNMP_TRAP_AUTH_PASSWORD" \
        -x "$SNMP_TRAP_PRIV_PROTOCOL" -X "$SNMP_TRAP_PRIV_PASSWORD" \
        "$SNMP_TRAP_HOST:$SNMP_TRAP_PORT" '' \
        1.3.6.1.4.1.8072.2.3.0.1 \
        1.3.6.1.2.1.1.5.0 s "$(hostname)" \
        1.3.6.1.4.1.8072.999.1.1.0 s "$HEALTH_STATUS" \
        1.3.6.1.4.1.8072.999.1.2.0 s "$SUMMARY"; then
        printf '%s\n' "$HEALTH_STATUS" > "$SNMP_STATE"
        logger -t unraid-health "$SUMMARY; SNMP trap sent"
    else
        logger -t unraid-health "$SUMMARY; SNMP trap failed"
    fi
}

send_health_trap

exit "$EXIT"
