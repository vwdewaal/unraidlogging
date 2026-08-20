#!/bin/bash

SYSLOG="/mnt/user/system-logs/syslog-Tower.log"
OUTDIR="/mnt/user/system-logs/events"
OUTFILE="$OUTDIR/critical-events.log"
STATE="/tmp/unraid-event-extract.offset"

logs_root_ready()
{
    mdcmd status 2>/dev/null | grep -qx 'mdState=STARTED' || return 1
    grep -qs '[[:space:]]/mnt/user[[:space:]]fuse\.shfs[[:space:]]' /proc/mounts
}

logs_root_ready || exit 0

mkdir -p "$OUTDIR"

[ -f "$SYSLOG" ] || exit 0

LINES=$(wc -l < "$SYSLOG")

if [ ! -f "$STATE" ]; then
    echo "$LINES" > "$STATE"
    exit 0
fi

LAST=$(cat "$STATE" 2>/dev/null)

case "$LAST" in
    ''|*[!0-9]*) LAST=0 ;;
esac

# Syslog rotated/truncated
if [ "$LINES" -lt "$LAST" ]; then
    LAST=0
fi

START=$((LAST + 1))

if [ "$START" -le "$LINES" ]; then
    sed -n "${START},${LINES}p" "$SYSLOG" |
    grep -Ei \
'oom|out of memory|killed process|oom-kill|segfault|general protection fault|machine check|mce:|hardware error|watchdog|soft lockup|hard lockup|hung task|blocked for more than|kernel panic|call trace|BUG:|I/O error|buffer I/O error|blk_update_request|ata[0-9].*(error|failed|reset|timeout|link is slow|exception)|SATA link down|hard resetting link|softreset failed|failed command|uncorrectable|CRC error|nvme.*(error|reset|timeout|abort|failed)|XFS.*(error|corrupt|shutdown)|BTRFS.*(error|corrupt|failed)|ZFS.*(fault|degrad|error|checksum)|zpool.*(fault|degrad)|md.*error|disk.*error|read error|write error|filesystem error|FAT-fs.*error|usb.*disconnect|USB disconnect|link.*down|link.*up|NIC.*error|NETDEV WATCHDOG|r8169.*(error|down|reset)|docker.*(oom|die|kill|restart|error)|thermal.*(warning|critical)|temperature.*(critical|warning)' \
    >> "$OUTFILE"
fi

echo "$LINES" > "$STATE"

# Keep event file manageable.
if [ -f "$OUTFILE" ] && [ "$(stat -c %s "$OUTFILE")" -gt 52428800 ]; then
    mv "$OUTFILE" "$OUTFILE.$(date +%Y%m%d-%H%M%S)"
fi
