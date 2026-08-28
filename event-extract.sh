#!/bin/bash

# Unraid keeps its active syslog in RAM.  Read it directly so event capture
# continues without requiring rsyslog to write continuously to /mnt/user.
SYSLOG="/var/log/syslog"
OUTDIR="/mnt/user/system-logs/events"
OUTFILE="$OUTDIR/critical-events.log"
STATE="/tmp/unraid-event-extract.offset"
MIGRATION_MARKER="$OUTDIR/.event-extractor-live-syslog-v1"
FILTER_MARKER="$OUTDIR/.event-extractor-filter-v2"

logs_root_ready()
{
    mdcmd status 2>/dev/null | grep -qx 'mdState=STARTED' || return 1
    grep -qs '[[:space:]]/mnt/user[[:space:]]fuse\.shfs[[:space:]]' /proc/mounts
}

logs_root_ready || exit 0

mkdir -p "$OUTDIR"

[ -f "$SYSLOG" ] || exit 0

# The previous extractor read a persistent rsyslog file which is no longer
# updated.  Preserve its historical entries once, then start a clean stream of
# live events so health reports do not keep warning about stale incidents.
if [ ! -f "$MIGRATION_MARKER" ]; then
    if [ -s "$OUTFILE" ]; then
        mv "$OUTFILE" "$OUTDIR/critical-events.pre-live-syslog-$(date '+%Y%m%d-%H%M%S').log"
    fi
    : > "$OUTFILE"
    touch "$MIGRATION_MARKER"
fi

# Version 1 of the live filter was intentionally broad and recorded harmless
# boot-time link messages plus DEBUG lines containing the substring "BUG:".
# Keep that first capture for reference and begin a clean, useful alert stream.
if [ ! -f "$FILTER_MARKER" ]; then
    if [ -s "$OUTFILE" ]; then
        mv "$OUTFILE" "$OUTDIR/critical-events.pre-filter-v2-$(date '+%Y%m%d-%H%M%S').log"
    fi
    : > "$OUTFILE"
    touch "$FILTER_MARKER"
fi

LINES=$(wc -l < "$SYSLOG")
SOURCE_ID=$(stat -c '%d:%i' "$SYSLOG" 2>/dev/null)

LAST_SOURCE_ID=""
LAST=0

if [ -f "$STATE" ]; then
    read -r LAST_SOURCE_ID LAST < "$STATE"
fi

case "$LAST" in
    ''|*[!0-9]*) LAST=0 ;;
esac

# Process a fresh syslog from its beginning. /tmp is cleared at boot, so this
# records relevant messages from the current boot once the extractor runs.
if [ "$SOURCE_ID" != "$LAST_SOURCE_ID" ] || [ "$LINES" -lt "$LAST" ]; then
    LAST=0
fi

START=$((LAST + 1))

if [ "$START" -le "$LINES" ]; then
    sed -n "${START},${LINES}p" "$SYSLOG" |
    grep -Ei \
'oom|out of memory|killed process|oom-kill|segfault|general protection fault|machine check|mce:|hardware error|watchdog|soft lockup|hard lockup|hung task|blocked for more than|kernel panic|call trace|\bBUG:|I/O error|buffer I/O error|blk_update_request|ata[0-9].*(error|failed|reset|timeout|link is slow|exception)|SATA link down|hard resetting link|softreset failed|failed command|uncorrectable|CRC error|nvme.*(error|reset|timeout|abort|failed)|XFS.*(error|corrupt|shutdown)|BTRFS.*(error|corrupt|failed)|ZFS.*(fault|degrad|error|checksum)|zpool.*(fault|degrad)|md.*error|disk.*error|read error|write error|filesystem error|FAT-fs.*error|usb.*disconnect|USB disconnect|NIC.*error|NETDEV WATCHDOG|r8169.*(error|down|reset)|docker.*(oom|die|kill|restart|error)|thermal.*(warning|critical)|temperature.*(critical|warning)' \
    >> "$OUTFILE"
fi

printf '%s %s\n' "$SOURCE_ID" "$LINES" > "$STATE"

# Keep event file manageable.
if [ -f "$OUTFILE" ] && [ "$(stat -c %s "$OUTFILE")" -gt 52428800 ]; then
    mv "$OUTFILE" "$OUTFILE.$(date +%Y%m%d-%H%M%S)"
fi
