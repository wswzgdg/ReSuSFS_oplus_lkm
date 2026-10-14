#!/bin/sh
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
MODDIR="/data/adb/modules/ReSuSFS"
PERSISTENT_DIR="/data/adb/ReSuSFS"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
	sleep 1
done

(
	last_status=
	while [ "$(getprop sys.boot_completed)" = "1" ]; do
		current_status=$(sh "$MODDIR/ReSuSFS.sh" --status-report 2>&1)
		if [ "$current_status" != "$last_status" ]; then
			printf '%s\n' "$current_status"
			last_status=$current_status
		fi
		sleep 30
	done
) &
