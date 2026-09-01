#!/bin/bash

# Forced-command endpoint for the unraidlogging-status SSH key. It accepts one
# literal command and prints a bounded, read-only morning health report.
if [ "${SSH_ORIGINAL_COMMAND:-}" != "status" ]; then
    echo "This key only permits: status" >&2
    exit 1
fi

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

echo "======================================================================"
echo " TOWER STATUS REPORT"
echo "======================================================================"
date
uptime

echo
echo "### RECENT CRITICAL EVENTS ###########################################"
tail -n 40 /mnt/user/system-logs/events/critical-events.log 2>/dev/null || \
    echo "No persistent event log yet."

echo
echo "### HEALTH SUMMARY ####################################################"
/boot/config/system-logging/unraid-health.sh

echo
echo "### RECENT SYSLOG #####################################################"
tail -n 120 /var/log/syslog 2>/dev/null || echo "Live syslog unavailable."
