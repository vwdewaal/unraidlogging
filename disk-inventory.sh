#!/bin/bash

MDSTATUS="$(mdcmd status 2>/dev/null)"

printf "%-10s %-12s %-28s %s\n" \
    "ROLE" "DEVICE" "MODEL" "SERIAL"

printf "%-10s %-12s %-28s %s\n" \
    "----------" "------------" "----------------------------" "--------------------"

echo "$MDSTATUS" |
awk -F= '
    /^diskName\.[0-9]+=/ {
        slot=$1
        sub(/^diskName\./,"",slot)
        name[slot]=$2
    }

    /^rdevName\.[0-9]+=/ {
        slot=$1
        sub(/^rdevName\./,"",slot)
        dev[slot]=$2
    }

    END {
        for (i in dev) {
            if (dev[i] != "")
                print i "|" dev[i]
        }
    }
' |
sort -t'|' -k1,1n |
while IFS='|' read -r SLOT DEV
do
    [ -b "/dev/$DEV" ] || continue

    INFO="$(smartctl -i -n standby "/dev/$DEV" 2>/dev/null)"

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
    [ -n "$SERIAL" ] || SERIAL="UNKNOWN"

if [ "$SLOT" -eq 0 ]; then
    ROLE="parity"
else
    ROLE="disk$SLOT"
fi

printf "%-10s %-12s %-28s %s\n" \
    "$ROLE" "/dev/$DEV" "$MODEL" "$SERIAL"
done
