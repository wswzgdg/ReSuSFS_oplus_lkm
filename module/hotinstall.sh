#!/bin/sh
PATH=/data/adb/ksu/bin:$PATH
MODDIR="/data/adb/modules/ReSuSFS"
PERSISTENT_DIR="/data/adb/ReSuSFS"

# Metamodule managers (MetaManager, nomount, mountify, zeromount) hot-install
# modules without rebooting and run MODULE_HOT_RUN_SCRIPT instead. KernelSU never
# reads that flag, so this file only matters when such a manager is in charge.
if [ -f "$PERSISTENT_DIR/lkm_enabled" ]; then
	sh "$MODDIR/ReSuSFS.sh" --lkm-load > /dev/null 2>&1
fi

sh "$MODDIR/post-fs-data.sh" > /dev/null 2>&1

sh "$MODDIR/boot-completed.sh" > /dev/null 2>&1

sh "$MODDIR/service.sh" > /dev/null 2>&1

echo "ReSuSFS: hot-install.sh done" >> /dev/kmsg
