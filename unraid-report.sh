#!/bin/bash

LOGROOT="/mnt/user/system-logs"
EVENTFILE="$LOGROOT/events/critical-events.log"
TODAY="$(date +%F)"
BLACKBOX="$LOGROOT/blackbox/$TODAY.log"

PASS=0
WARN=0
FAIL=0

line()
{
    printf '%-30s %s\n' "$1" "$2"
}

echo
echo "======================================================================"
echo " TOWER HEALTH REPORT"
echo "======================================================================"
echo
line "Generated:" "$(date)"
line "Uptime:" "$(uptime -p)"
line "Load:" "$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
echo

########################################################################
# OVERALL HEALTH
########################################################################

echo "OVERALL"
echo "----------------------------------------------------------------------"

HEALTH_OUTPUT="$(/boot/config/system-logging/unraid-health.sh 2>&1)"
HEALTH_RC=$?

PASS_COUNT="$(echo "$HEALTH_OUTPUT" | awk '/^PASS :/ {print $3}')"
WARN_COUNT="$(echo "$HEALTH_OUTPUT" | awk '/^WARN :/ {print $3}')"
FAIL_COUNT="$(echo "$HEALTH_OUTPUT" | awk '/^FAIL :/ {print $3}')"
OVERALL="$(echo "$HEALTH_OUTPUT" | awk -F': ' '/^OVERALL STATUS:/ {print $2}')"

line "Status:" "${OVERALL:-UNKNOWN}"
line "Passed checks:" "${PASS_COUNT:-0}"
line "Warnings:" "${WARN_COUNT:-0}"
line "Failures:" "${FAIL_COUNT:-0}"

########################################################################
# CAPACITY
########################################################################

echo
echo "STORAGE CAPACITY"
echo "----------------------------------------------------------------------"

df -P 2>/dev/null |
awk '
NR > 1 {
    gsub("%","",$5)

    if ($6 ~ "^/mnt/disk[0-9]+$") {
        status="OK"

        if ($5 >= 95)
            status="CRITICAL"
        else if ($5 >= 85)
            status="WARN"

        printf "%-15s %3s%%   %s\n", $6, $5, status
    }
}'

echo


while read -r FS SIZE USED AVAIL PCT MOUNT
do
    case "$MOUNT" in
        /mnt/disks/*)
            NUM="${PCT%\%}"

            if [ "$NUM" -ge 85 ]; then
                STATUS="WARN"
            else
                STATUS="OK"
            fi

            printf "%-35s %3s%%   %s\n" \
                "$MOUNT" "$NUM" "$STATUS"
            ;;
    esac

done < <(df -P 2>/dev/null | tail -n +2)
########################################################################
# ARRAY
########################################################################

echo
echo "ARRAY"
echo "----------------------------------------------------------------------"

if command -v mdcmd >/dev/null 2>&1; then

    ARRAY="$(mdcmd status 2>/dev/null)"

    if echo "$ARRAY" | grep -q 'mdState=STARTED'; then
        echo "[OK] Array started"
    else
        echo "[WARN] Array not reporting STARTED"
    fi

    ERRORS="$(echo "$ARRAY" |
        awk -F= '
        /rdevName/ {
            dev=$2
        }
        /rdevNumErrors/ {
            if ($2+0 > 0)
                print dev ": " $2 " errors"
        }'
    )"

    if [ -n "$ERRORS" ]; then
        echo "$ERRORS"
    else
        echo "[OK] No Unraid array disk errors"
    fi
fi

########################################################################
# ZFS
########################################################################

echo
echo "ZFS"
echo "----------------------------------------------------------------------"

if command -v zpool >/dev/null 2>&1; then

    ZPOOL="$(zpool status -x 2>&1)"

    if echo "$ZPOOL" | grep -qi 'all pools are healthy'; then
        echo "[OK] All pools healthy"
    else
        echo "$ZPOOL"
    fi

fi

########################################################################
# NVME
########################################################################

echo
echo "NVME"
echo "----------------------------------------------------------------------"

if [ -e /dev/nvme0 ]; then

    NVME="$(nvme smart-log /dev/nvme0 2>/dev/null)"

    echo "$NVME" |
    awk -F: '
    /critical_warning/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Critical warning:", $2
    }

    /^temperature/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Temperature:", $2
    }

    /available_spare[ \t]*:/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Available spare:", $2
    }

    /percentage_used/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Endurance used:", $2
    }

    /unsafe_shutdowns/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Unsafe shutdowns:", $2
    }

    /media_errors/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        printf "%-25s %s\n", "Media errors:", $2
    }
    '

fi

########################################################################
# DOCKER
########################################################################

echo
echo "DOCKER"
echo "----------------------------------------------------------------------"

if docker info >/dev/null 2>&1; then

    TOTAL="$(docker ps -a -q | wc -l)"
    RUNNING="$(docker ps -q | wc -l)"

    line "Containers:" "$TOTAL"
    line "Running:" "$RUNNING"

    UNHEALTHY="$(
        docker ps \
            --format '{{.Names}}|{{.Status}}' |
        grep -Ei '\(unhealthy\)'
    )"

    if [ -n "$UNHEALTHY" ]; then

        echo
        echo "Unhealthy:"

        echo "$UNHEALTHY" |
        while IFS='|' read -r NAME STATUS
        do
            echo "  [WARN] $NAME"
            echo "         $STATUS"
        done

    else
        echo "[OK] No running containers unhealthy"
    fi

    STOPPED="$(docker ps -a \
        --filter status=exited \
        --format '{{.Names}}' |
        wc -l)"

    line "Stopped:" "$STOPPED"

else
    echo "[FAIL] Docker daemon unavailable"
fi

########################################################################
# EVENTS - LAST 24 HOURS
########################################################################

echo
echo "EVENTS"
echo "----------------------------------------------------------------------"

if [ -f "$EVENTFILE" ]; then

    EVENTS24="$(
        awk -v now="$(date +%s)" '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",m)

            for (i=1;i<=12;i++)
                month[m[i]]=i
        }

        {
            mon=month[$1]
            day=$2

            if (!mon)
                next

            cmd="date -d \"" $1 " " day "\" +%s 2>/dev/null"
            cmd | getline t
            close(cmd)

            if ((now-t) <= 86400)
                print
        }' "$EVENTFILE" 2>/dev/null |
        grep -Eiv 'TEST I/O error event extractor'
    )"

    if [ -z "$EVENTS24" ]; then
        echo "[OK] No critical events in the last 24 hours"
    else
        COUNT="$(echo "$EVENTS24" | wc -l)"

        echo "[WARN] $COUNT critical-event entries in last 24 hours"
        echo
        echo "$EVENTS24" | tail -20
    fi

else
    echo "[OK] No critical-event log exists"
fi

########################################################################
# SPECIFIC FAILURE SEARCH
########################################################################

echo
echo "24-HOUR FAILURE SUMMARY"
echo "----------------------------------------------------------------------"

SEARCHFILES=""

if [ -f "$BLACKBOX" ]; then
    SEARCHFILES="$BLACKBOX"
fi

YESTERDAY="$(date -d 'yesterday' +%F)"
YLOG="$LOGROOT/blackbox/$YESTERDAY.log"

if [ -f "$YLOG" ]; then
    SEARCHFILES="$SEARCHFILES $YLOG"
fi

check_pattern()
{
    LABEL="$1"
    PATTERN="$2"

    if [ -z "$SEARCHFILES" ]; then
        printf "%-28s %s\n" "$LABEL" "NO DATA"
        return
    fi

    COUNT="$(grep -Eic "$PATTERN" $SEARCHFILES 2>/dev/null)"

    if [ "$COUNT" -eq 0 ]; then
        printf "%-28s %s\n" "$LABEL" "0"
    else
        printf "%-28s %s  <-- REVIEW\n" "$LABEL" "$COUNT"
    fi
}

check_pattern "OOM / memory kills:" \
    'out of memory|oom-kill|killed process'

check_pattern "Disk I/O errors:" \
    'I/O error|buffer I/O error|blk_update_request'

check_pattern "SATA resets/errors:" \
    'ata[0-9].*(error|failed|reset|timeout)|hard resetting link'

check_pattern "NVMe errors/resets:" \
    'nvme.*(error|reset|timeout|abort|failed)'

check_pattern "XFS errors:" \
    'XFS.*(error|corrupt|shutdown)'

check_pattern "BTRFS errors:" \
    'BTRFS.*(error|corrupt|failed)'

check_pattern "ZFS faults/errors:" \
    'ZFS.*(fault|degrad|error|checksum)'

check_pattern "Kernel panics:" \
    'kernel panic'

check_pattern "Hung tasks:" \
    'hung task|blocked for more than'

check_pattern "Machine check errors:" \
    'machine check|hardware error|mce:'

check_pattern "Network watchdog:" \
    'NETDEV WATCHDOG'

########################################################################
# LOGGER STATUS
########################################################################

echo
echo "LOGGING"
echo "----------------------------------------------------------------------"

# Persistent syslog
if pgrep -x rsyslogd >/dev/null 2>&1 &&
   [ -f "$LOGROOT/syslog-Tower.log" ]; then

    echo "Persistent syslog:       OK"

else

    echo "Persistent syslog:       FAIL"

fi


# Blackbox
if [ -f "$BLACKBOX" ]; then

    AGE=$(( $(date +%s) - $(stat -c %Y "$BLACKBOX") ))

    if [ "$AGE" -le 600 ]; then
        echo "Blackbox:                OK"
    else
        echo "Blackbox:                STALE ($((AGE / 60)) min)"
    fi

else

    echo "Blackbox:                MISSING"

fi


# Disk-health collector
DISKLOG="$LOGROOT/snapshots/disks/$TODAY.log"

if [ -f "$DISKLOG" ]; then

    AGE=$(( $(date +%s) - $(stat -c %Y "$DISKLOG") ))

    if [ "$AGE" -le 7200 ]; then
        echo "Disk health:             OK"
    else
        echo "Disk health:             STALE ($((AGE / 3600)) hr)"
    fi

else

    echo "Disk health:             MISSING"

fi


# Event extractor - check its state file, not critical-events.log
EVENTSTATE="/tmp/unraid-event-extract.offset"

if [ -f "$EVENTSTATE" ]; then

    AGE=$(( $(date +%s) - $(stat -c %Y "$EVENTSTATE") ))

    if [ "$AGE" -le 180 ]; then
        echo "Critical event extractor: OK"
    else
        echo "Critical event extractor: STALE ($((AGE / 60)) min)"
    fi

else

    echo "Critical event extractor: MISSING"

fi


# Daily snapshot
DAILY="$LOGROOT/snapshots/daily/$TODAY"

if [ -d "$DAILY" ]; then
    echo "Daily snapshot:          OK"
else
    echo "Daily snapshot:          NOT RUN TODAY"
fi
########################################################################
# RECENT BLACKBOX TREND
########################################################################

echo
echo "RECENT BLACKBOX"
echo "----------------------------------------------------------------------"

if [ -f "$BLACKBOX" ]; then

    LAST="$(grep '^Time:' "$BLACKBOX" | tail -1)"

    echo "Latest snapshot: ${LAST#Time: }"

    SIZE="$(du -h "$BLACKBOX" | awk '{print $1}')"
    echo "Today's log:     $SIZE"

else
    echo "No blackbox data for today."
fi

########################################################################
# TRENDS
########################################################################

echo
echo "TRENDS"
echo "----------------------------------------------------------------------"

DAILYROOT="$LOGROOT/snapshots/daily"

# Find oldest available daily snapshot, up to 30 days old.
OLDEST_DIR="$(
    find "$DAILYROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
    sort |
    head -n 1
)"

LATEST_DIR="$(
    find "$DAILYROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' 2>/dev/null |
    sort |
    tail -n 1
)"

if [ -z "$OLDEST_DIR" ] || [ -z "$LATEST_DIR" ]; then
    echo "Not enough historical data yet."
else

    echo "Comparison:"
    echo "  Oldest snapshot: $OLDEST_DIR"
    echo "  Latest snapshot: $LATEST_DIR"
    echo
fi
########################################################################
# NETWORK TRENDS
########################################################################

echo
echo "Network counters"
echo

OLD_NET="$DAILYROOT/$OLDEST_DIR/network.json"
NEW_NET="$DAILYROOT/$LATEST_DIR/network.json"

if [ ! -f "$OLD_NET" ] || [ ! -f "$NEW_NET" ]; then
    echo "Network trend data not yet available."

elif ! command -v jq >/dev/null 2>&1; then
    echo "jq is not installed - cannot parse network trend data."

else
    TMPOLD="/tmp/unraid-net-old.$$"
    TMPNEW="/tmp/unraid-net-new.$$"

    jq -r '
        .[] |
        select(.ifname != "lo") |
        [
            .ifname,
            (.stats64.rx.errors // 0),
            (.stats64.rx.dropped // 0),
            (.stats64.tx.errors // 0),
            (.stats64.tx.dropped // 0),
            (.stats64.tx.carrier_errors // 0),
            (.stats64.tx.collisions // 0)
        ] |
        @tsv
    ' "$OLD_NET" > "$TMPOLD"

    jq -r '
        .[] |
        select(.ifname != "lo") |
        [
            .ifname,
            (.stats64.rx.errors // 0),
            (.stats64.rx.dropped // 0),
            (.stats64.tx.errors // 0),
            (.stats64.tx.dropped // 0),
            (.stats64.tx.carrier_errors // 0),
            (.stats64.tx.collisions // 0)
        ] |
        @tsv
    ' "$NEW_NET" > "$TMPNEW"

    ACTIVITY=0

    while IFS=$'\t' read -r IFACE \
        NEW_RXERR NEW_RXDROP \
        NEW_TXERR NEW_TXDROP \
        NEW_CARRIER NEW_COLLISIONS
    do
        OLD_LINE="$(
            awk -F '\t' -v iface="$IFACE" \
                '$1 == iface {print; exit}' "$TMPOLD"
        )"

        if [ -z "$OLD_LINE" ]; then
            printf "%-20s new interface\n" "$IFACE"
            continue
        fi

        IFS=$'\t' read -r OLD_IFACE \
            OLD_RXERR OLD_RXDROP \
            OLD_TXERR OLD_TXDROP \
            OLD_CARRIER OLD_COLLISIONS \
            <<< "$OLD_LINE"

        DRXERR=$((NEW_RXERR - OLD_RXERR))
        DRXDROP=$((NEW_RXDROP - OLD_RXDROP))
        DTXERR=$((NEW_TXERR - OLD_TXERR))
        DTXDROP=$((NEW_TXDROP - OLD_TXDROP))
        DCARRIER=$((NEW_CARRIER - OLD_CARRIER))
        DCOLLISIONS=$((NEW_COLLISIONS - OLD_COLLISIONS))

        if [ "$DRXERR" -ne 0 ] ||
           [ "$DRXDROP" -ne 0 ] ||
           [ "$DTXERR" -ne 0 ] ||
           [ "$DTXDROP" -ne 0 ] ||
           [ "$DCARRIER" -ne 0 ] ||
           [ "$DCOLLISIONS" -ne 0 ]; then

            ACTIVITY=1

            echo "$IFACE"

            printf "  RX errors       %s -> %s   delta %+d\n" \
                "$OLD_RXERR" "$NEW_RXERR" "$DRXERR"

            printf "  RX dropped      %s -> %s   delta %+d\n" \
                "$OLD_RXDROP" "$NEW_RXDROP" "$DRXDROP"

            printf "  TX errors       %s -> %s   delta %+d\n" \
                "$OLD_TXERR" "$NEW_TXERR" "$DTXERR"

            printf "  TX dropped      %s -> %s   delta %+d\n" \
                "$OLD_TXDROP" "$NEW_TXDROP" "$DTXDROP"

            printf "  Carrier errors  %s -> %s   delta %+d\n" \
                "$OLD_CARRIER" "$NEW_CARRIER" "$DCARRIER"

            printf "  Collisions      %s -> %s   delta %+d\n" \
                "$OLD_COLLISIONS" "$NEW_COLLISIONS" "$DCOLLISIONS"

            echo
        fi

    done < "$TMPNEW"

    rm -f "$TMPOLD" "$TMPNEW"

    if [ "$ACTIVITY" -eq 0 ]; then
        echo "No network error-counter increases detected."
    fi
fi
echo "Disk capacity"
echo

OLD_SYSTEM="$DAILYROOT/$OLDEST_DIR/system.txt"
NEW_SYSTEM="$DAILYROOT/$LATEST_DIR/system.txt"

for DISK in disk1 disk2 disk3 disk4 disk5 disk6
do
    OLD="$(
        awk -v mount="/mnt/$DISK" '
            $1 ~ /^\/dev\/md/ && $NF == mount {
                pct=$(NF-1)
                gsub("%","",pct)
                print pct
                exit
            }
        ' "$OLD_SYSTEM"
    )"

    NEW="$(
        awk -v mount="/mnt/$DISK" '
            $1 ~ /^\/dev\/md/ && $NF == mount {
                pct=$(NF-1)
                gsub("%","",pct)
                print pct
                exit
            }
        ' "$NEW_SYSTEM"
    )"

    if [[ "$OLD" =~ ^[0-9]+$ ]] &&
       [[ "$NEW" =~ ^[0-9]+$ ]]; then

        CHANGE=$((NEW - OLD))

        if [ "$CHANGE" -gt 0 ]; then
            SIGN="+"
        else
            SIGN=""
        fi

        printf "%-8s %3d%% -> %3d%%   %s%d%%" \
            "$DISK" "$OLD" "$NEW" "$SIGN" "$CHANGE"

        if [ "$NEW" -ge 95 ]; then
            printf "   CRITICAL"
        elif [ "$NEW" -ge 85 ]; then
            printf "   WARN"
        fi

        echo
    else
        printf "%-8s no capacity data\n" "$DISK"
    fi
done
    ####################################################################
    # NVME
    ####################################################################

    echo
    echo "NVMe"
    echo

    OLD_NVME="$DAILYROOT/$OLDEST_DIR/smart/nvme0-smart.txt"
    NEW_NVME="$DAILYROOT/$LATEST_DIR/smart/nvme0-smart.txt"

    if [ -f "$OLD_NVME" ] && [ -f "$NEW_NVME" ]; then

        old_nvme_value()
        {
            awk -F: -v key="$1" '
            $1 ~ key {
                gsub(/^[ \t]+|[ \t%]+$/, "", $2)
                print $2
                exit
            }' "$OLD_NVME"
        }

        new_nvme_value()
        {
            awk -F: -v key="$1" '
            $1 ~ key {
                gsub(/^[ \t]+|[ \t%]+$/, "", $2)
                print $2
                exit
            }' "$NEW_NVME"
        }

        OLD_WEAR="$(old_nvme_value "percentage_used")"
        NEW_WEAR="$(new_nvme_value "percentage_used")"

        OLD_MEDIA="$(old_nvme_value "media_errors")"
        NEW_MEDIA="$(new_nvme_value "media_errors")"

        OLD_UNSAFE="$(old_nvme_value "unsafe_shutdowns")"
        NEW_UNSAFE="$(new_nvme_value "unsafe_shutdowns")"

        OLD_ERRLOG="$(old_nvme_value "num_err_log_entries")"
        NEW_ERRLOG="$(new_nvme_value "num_err_log_entries")"

        if [[ "$OLD_WEAR" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_WEAR" =~ ^[0-9]+$ ]]; then
            printf "%-24s %s%% -> %s%%\n" \
                "Endurance used:" "$OLD_WEAR" "$NEW_WEAR"
        fi

        if [[ "$OLD_MEDIA" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_MEDIA" =~ ^[0-9]+$ ]]; then
            printf "%-24s %s -> %s\n" \
                "Media errors:" "$OLD_MEDIA" "$NEW_MEDIA"
        fi

        if [[ "$OLD_UNSAFE" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_UNSAFE" =~ ^[0-9]+$ ]]; then
            printf "%-24s %s -> %s\n" \
                "Unsafe shutdowns:" "$OLD_UNSAFE" "$NEW_UNSAFE"
        fi

        if [[ "$OLD_ERRLOG" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_ERRLOG" =~ ^[0-9]+$ ]]; then
            printf "%-24s %s -> %s\n" \
                "NVMe error entries:" "$OLD_ERRLOG" "$NEW_ERRLOG"
        fi
    else
        echo "No NVMe trend data available."
    fi
########################################################################
# DISK INVENTORY / REPLACEMENT DETECTION
########################################################################

echo
echo "Disk identity changes"
echo

OLD_INV="$DAILYROOT/$OLDEST_DIR/disk-inventory.tsv"
NEW_INV="$DAILYROOT/$LATEST_DIR/disk-inventory.tsv"

if [ -f "$OLD_INV" ] && [ -f "$NEW_INV" ]; then

    # Compare each current role against the oldest snapshot.
    while IFS=$'\t' read -r ROLE DEVICE MODEL SERIAL
    do
        [ "$ROLE" = "ROLE" ] && continue
        [ -n "$ROLE" ] || continue

        OLD_LINE="$(
            awk -F '\t' -v role="$ROLE" '
                NR > 1 && $1 == role {
                    print
                    exit
                }
            ' "$OLD_INV"
        )"

        if [ -z "$OLD_LINE" ]; then
            echo "[NEW] $ROLE"
            echo "      Device: $DEVICE"
            echo "      Model:  $MODEL"
            echo "      Serial: $SERIAL"
            echo
            continue
        fi

        IFS=$'\t' read -r OLD_ROLE OLD_DEVICE OLD_MODEL OLD_SERIAL \
            <<< "$OLD_LINE"

        if [ "$SERIAL" != "$OLD_SERIAL" ]; then
            echo "[REPLACED] $ROLE"
            echo "      Previous serial: $OLD_SERIAL"
            echo "      Previous model:  $OLD_MODEL"
            echo "      Current serial:  $SERIAL"
            echo "      Current model:   $MODEL"
            echo
        elif [ "$DEVICE" != "$OLD_DEVICE" ]; then
            echo "[DEVICE CHANGE] $ROLE"
            echo "      Serial: $SERIAL"
            echo "      $OLD_DEVICE -> $DEVICE"
            echo "      Physical disk unchanged"
            echo
        fi

    done < "$NEW_INV"

    # Detect roles that existed before but are now absent.
    while IFS=$'\t' read -r ROLE DEVICE MODEL SERIAL
    do
        [ "$ROLE" = "ROLE" ] && continue
        [ -n "$ROLE" ] || continue

        if ! awk -F '\t' -v role="$ROLE" '
            NR > 1 && $1 == role { found=1 }
            END { exit !found }
        ' "$NEW_INV"
        then
            echo "[REMOVED] $ROLE"
            echo "      Previous device: $DEVICE"
            echo "      Previous model:  $MODEL"
            echo "      Previous serial: $SERIAL"
            echo
        fi

    done < "$OLD_INV"

else
    echo "Disk inventory trend data not yet available."
fi


########################################################################
# SMART MEDIA COUNTERS BY PHYSICAL SERIAL
########################################################################

echo
echo "SMART media counters"
echo

if [ -f "$NEW_INV" ]; then

    while IFS=$'\t' read -r ROLE DEVICE MODEL SERIAL
    do
        [ "$ROLE" = "ROLE" ] && continue
        [ -n "$SERIAL" ] || continue

        SAFE_SERIAL="$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_')"

        NEW_SMART="$DAILYROOT/$LATEST_DIR/smart/$SAFE_SERIAL.txt"
        OLD_SMART="$DAILYROOT/$OLDEST_DIR/smart/$SAFE_SERIAL.txt"

        printf "%-8s %-22s " "$ROLE" "$SERIAL"

        if [ ! -f "$NEW_SMART" ]; then
            echo "no current SMART data"
            continue
        fi

        if grep -q "STANDBY" "$NEW_SMART"; then
            echo "sleeping at latest snapshot"
            continue
        fi

        NEW_REALLOC="$(
            awk '/Reallocated_Sector_Ct/ {print $NF; exit}' "$NEW_SMART"
        )"

        NEW_PENDING="$(
            awk '/Current_Pending_(Sector|ECC_Cnt)/ {print $NF; exit}' \
                "$NEW_SMART"
        )"

        NEW_UNCORR="$(
            awk '/Offline_Uncorrectable/ {print $NF; exit}' "$NEW_SMART"
        )"

        [ -n "$NEW_REALLOC" ] || NEW_REALLOC="n/a"
        [ -n "$NEW_PENDING" ] || NEW_PENDING="n/a"
        [ -n "$NEW_UNCORR" ] || NEW_UNCORR="n/a"

        # If the same physical disk didn't exist in the oldest snapshot,
        # this is a new/replacement disk and should start a new baseline.
        if [ ! -f "$OLD_SMART" ]; then
            echo "new baseline: realloc=$NEW_REALLOC pending=$NEW_PENDING uncorrectable=$NEW_UNCORR"
            continue
        fi

        if grep -q "STANDBY" "$OLD_SMART"; then
            echo "current: realloc=$NEW_REALLOC pending=$NEW_PENDING uncorrectable=$NEW_UNCORR (old snapshot asleep)"
            continue
        fi

        OLD_REALLOC="$(
            awk '/Reallocated_Sector_Ct/ {print $NF; exit}' "$OLD_SMART"
        )"

        OLD_PENDING="$(
            awk '/Current_Pending_(Sector|ECC_Cnt)/ {print $NF; exit}' \
                "$OLD_SMART"
        )"

        OLD_UNCORR="$(
            awk '/Offline_Uncorrectable/ {print $NF; exit}' "$OLD_SMART"
        )"

        [ -n "$OLD_REALLOC" ] || OLD_REALLOC="n/a"
        [ -n "$OLD_PENDING" ] || OLD_PENDING="n/a"
        [ -n "$OLD_UNCORR" ] || OLD_UNCORR="n/a"

        echo

        printf "         realloc       %s -> %s" \
            "$OLD_REALLOC" "$NEW_REALLOC"

        if [[ "$OLD_REALLOC" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_REALLOC" =~ ^[0-9]+$ ]] &&
           [ "$NEW_REALLOC" -gt "$OLD_REALLOC" ]; then
            printf "   <-- INCREASE"
        fi
        echo

        printf "         pending       %s -> %s" \
            "$OLD_PENDING" "$NEW_PENDING"

        if [[ "$OLD_PENDING" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_PENDING" =~ ^[0-9]+$ ]] &&
           [ "$NEW_PENDING" -gt "$OLD_PENDING" ]; then
            printf "   <-- INCREASE"
        fi
        echo

        printf "         uncorrectable %s -> %s" \
            "$OLD_UNCORR" "$NEW_UNCORR"

        if [[ "$OLD_UNCORR" =~ ^[0-9]+$ ]] &&
           [[ "$NEW_UNCORR" =~ ^[0-9]+$ ]] &&
           [ "$NEW_UNCORR" -gt "$OLD_UNCORR" ]; then
            printf "   <-- INCREASE"
        fi
        echo

    done < "$NEW_INV"

else
    echo "No current disk inventory available."
fi
########################################################################
# RECOMMENDATIONS
########################################################################

echo
echo "ATTENTION"
echo "----------------------------------------------------------------------"

ATTENTION=0

df -P 2>/dev/null |
awk '
NR > 1 {
    gsub("%","",$5)

    if ($6 ~ "^/mnt/disk[0-9]+$" && $5 >= 85)
        print "[WARN] " $6 " is " $5 "% full"
}' |
while read -r LINE
do
    echo "$LINE"
done

if docker info >/dev/null 2>&1; then

    docker ps \
        --format '{{.Names}}|{{.Status}}' |
    grep -Ei '\(unhealthy\)' |
    while IFS='|' read -r NAME STATUS
    do
        echo "[WARN] Docker container unhealthy: $NAME"
    done

fi

echo
echo "======================================================================"
echo " END OF REPORT"
echo "======================================================================"
echo
echo "For full interactive health:"
echo "  unraid-health"
echo
echo "For a forensic diagnostics bundle:"
echo "  unraid-diag"
echo
