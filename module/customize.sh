#!/bin/sh

DEST_BIN_DIR=/data/adb/ksu/bin
PERSISTENT_DIR=/data/adb/ReSuSFS

. "$MODPATH/utils.sh"

export MODULE_HOT_INSTALL_REQUEST="true"
export MODULE_HOT_RUN_SCRIPT="hotinstall.sh"

banner "$MODPATH"

ui_print "[%] customize.sh "

detect_key_press() {
	timeout_seconds=6
	line=$(timeout "$timeout_seconds" getevent -ql 2>/dev/null | awk '/KEY_VOLUME(UP|DOWN)/ { print; fflush(); exit }')
	case "$line" in
		*KEY_VOLUMEUP*) return 0 ;;
		*KEY_VOLUMEDOWN*) ui_print "[*] Volume down selected"; return 1 ;;
		*) ui_print "[!] No volume key detected within $timeout_seconds seconds"; return 1 ;;
	esac
}

brand=$(getprop ro.product.brand | tr '[:upper:]' '[:lower:]')
manufacturer=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')
if echo "$brand $manufacturer" | grep -Eq 'oppo|oneplus|realme' && ! "$DEST_BIN_DIR/ksu_susfs" show version >/dev/null 2>&1; then
	ui_print "[*] No working native ksu_susfs detected. Optional exact-KMI SUSFS LKM download?"
	ui_print "[*] VOLUME UP to download and enable for next boot, DOWN to skip"
	if detect_key_press; then
		if sh "$MODPATH/install_susfs_lkm.sh"; then
			mkdir -p "$PERSISTENT_DIR"
			echo 1 > "$PERSISTENT_DIR/lkm_enabled"
			ui_print "[+] LKM installed and enabled for next boot; reboot required"
		else
			ui_print "[!] LKM install failed; continuing without it"
		fi
	else
		ui_print "[*] Skipping optional SUSFS LKM"
	fi
fi

if [ -d "$PERSISTENT_DIR" ]; then
	ui_print "[*] Have you backed up your configuration?"
	ui_print "[*] VOLUME UP for YES, DOWN for NO"
	if ! detect_key_press; then
		ui_print "[!] Please back up your configuration first"
		exit 1
	fi
fi

CONFIG_DIR="$MODPATH/configs"

[ ! -d "$CONFIG_DIR" ] || [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ] && ui_print "[!] No config files found" && exit 0

collect_changed() {
	src_dir="$1"
	dst_dir="$2"
	files="$3"
	for file in $files; do
		src="$src_dir/$file"
		dst="$dst_dir/$file"
		if [ ! -f "$dst" ]; then
			mkdir -p "$dst_dir/$(dirname "$file")"
			cp "$src" "$dst"
			ui_print "[+] $file copied"
		elif ! cmp -s "$src" "$dst"; then
			printf '%s\n' "$file"
		fi
	done
}

apply_changed() {
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if [ "${file#scripts/}" != "$file" ]; then
			src="$CONFIG_DIR/scripts/$file"
			dst="$PERSISTENT_DIR/scripts/$file"
		else
			src="$CONFIG_DIR/$file"
			dst="$PERSISTENT_DIR/$file"
		fi
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
		ui_print "[+] $file updated"
	done
}

CHANGED_FILES=$(collect_changed "$CONFIG_DIR" "$PERSISTENT_DIR" "scripts_bootcompleted.txt scripts_postfs.txt")
if [ -d "$CONFIG_DIR/scripts" ]; then
	CHANGED_FILES="$CHANGED_FILES
$(collect_changed "$CONFIG_DIR/scripts" "$PERSISTENT_DIR/scripts" "$(get_all_files "$CONFIG_DIR/scripts")")"
fi

CONFIG_FILES=$(get_all_files "$CONFIG_DIR" | grep -v '^scripts/')
if [ -n "$CONFIG_FILES" ]; then
	CHANGED_FILES="$CHANGED_FILES
$(collect_changed "$CONFIG_DIR" "$PERSISTENT_DIR" "$CONFIG_FILES")"
fi

if [ -n "$(printf '%s\n' "$CHANGED_FILES" | sed '/^[[:space:]]*$/d')" ]; then
	ui_print "[*] Changed files:"
	printf '%s\n' "$CHANGED_FILES" | sed '/^[[:space:]]*$/d' | while IFS= read -r file; do
		ui_print "    - $file"
	done
	ui_print "[*] VOLUME UP to apply all updates, DOWN to keep current files"
	if detect_key_press; then
		apply_changed "$CONFIG_DIR" "$PERSISTENT_DIR" <<EOF
$CHANGED_FILES
EOF
	else
		ui_print "[+] Kept existing files"
	fi
fi

rm -rf "$CONFIG_DIR"

update_susfs || exit 1

chmod 755 "$MODPATH/ReSuSFS.sh"
chmod 644 "$MODPATH/post-fs-data.sh" "$MODPATH/service.sh" "$MODPATH/uninstall.sh" 2>/dev/null

if [ -d "$DEST_BIN_DIR" ]; then
	ui_print "[+] creating symlink in $DEST_BIN_DIR"
	ln -sf "/data/adb/modules/ReSuSFS/ReSuSFS.sh" "$DEST_BIN_DIR/ReSuSFS"
fi

if [ ! -d "$PERSISTENT_DIR/.webui_config" ] || [ ! -f "$PERSISTENT_DIR/.webui_config/custom.css" ]; then
	mkdir -p "$PERSISTENT_DIR/.webui_config"
	mv "$MODPATH/custom.css" "$PERSISTENT_DIR/.webui_config/custom.css"
else
	rm -f "$MODPATH/custom.css"
fi

# EOF
