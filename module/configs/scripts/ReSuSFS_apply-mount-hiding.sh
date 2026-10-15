#!/system/bin/sh
#title=Hide mounts
#author=ahmed-alnassif
#desc=Hides module mounts redirected to system paths

PATH=/data/adb/ksu/bin:/data/data/com.termux/files/usr/bin:$PATH


# LKM-only mode check: skip if native SUSFS CLI is unavailable
if [ -d /sys/module/susfs_guard_lkm ] && [ ! -x /data/adb/ksu/bin/ksu_susfs ]; then
    echo "[*] LKM-only mode: skipping $(basename "$0") (requires native SUSFS CLI for add_sus_path_loop)"
    exit 0
fi

LIST_FILE="/data/adb/ReSuSFS/tmp_mount_hiding.txt"

: > "$LIST_FILE"

while IFS=' ' read -r device mount_point fs_type remainder; do
	case "$mount_point" in
		/data/adb/modules/*)
			echo "$mount_point" >> "$LIST_FILE"
			;;
	esac
done < /proc/mounts

while IFS=' ' read -r device mount_point fs_type remainder; do
	case "$device" in
		/data/adb/modules/*)
			echo "$mount_point" >> "$LIST_FILE"
			;;
	esac
done < /proc/mounts

sort -u "$LIST_FILE" -o "$LIST_FILE"

if [ -s "$LIST_FILE" ]; then
	if ReSuSFS --apply-sus-paths-loop "$LIST_FILE"; then
		echo "[+] mount hiding applied successfully"
		echo "[*] reboot recommended if you want the resulting state to be refreshed from boot"
	else
		echo "[-] mount hiding apply failed"
		echo "[*] no reboot required"
	fi
else
	echo "[*] no suspicious mounts found, nothing applied"
	echo "[*] no reboot required"
fi

rm -f "$LIST_FILE"
