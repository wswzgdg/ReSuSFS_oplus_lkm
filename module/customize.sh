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

# $PERSISTENT_DIR is never deleted by install or uninstall, so the user's config is
# kept automatically: no prompt, and nothing to ask when the dir does not exist.
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
			cp "$src" "$dst" || { ui_print "[-] $file copy failed"; continue; }
			ui_print "[+] $file copied"
		elif ! cmp -s "$src" "$dst"; then
			ui_print "[+] $file changed"
			printf '%s\n' "$file" >> "$CHANGED_FILES"
		fi
	done
}

apply_changed() {
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		if [ "${file#scripts/}" != "$file" ]; then
			src="$CONFIG_DIR/scripts/${file#scripts/}"
			dst="$PERSISTENT_DIR/scripts/${file#scripts/}"
		elif [ -f "$CONFIG_DIR/scripts/$file" ]; then
			src="$CONFIG_DIR/scripts/$file"
			dst="$PERSISTENT_DIR/scripts/$file"
		else
			src="$CONFIG_DIR/$file"
			dst="$PERSISTENT_DIR/$file"
		fi
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst" || { ui_print "[-] $file update failed"; continue; }
		ui_print "[+] $file updated"
	done
}

mkdir -p "$PERSISTENT_DIR"
CHANGED_FILES=$(mktemp -p "$PERSISTENT_DIR" '.changed.XXXXXX' 2>/dev/null || printf '%s' "$PERSISTENT_DIR/.changed.$$")
: > "$CHANGED_FILES"
if [ -d "$CONFIG_DIR/scripts" ]; then
	collect_changed "$CONFIG_DIR" "$PERSISTENT_DIR" "$(get_all_files "$CONFIG_DIR/scripts" | sed 's|^|scripts/|')"
fi

CONFIG_FILES=$(get_all_files "$CONFIG_DIR" | grep -v '^scripts/')
if [ -n "$CONFIG_FILES" ]; then
	collect_changed "$CONFIG_DIR" "$PERSISTENT_DIR" "$CONFIG_FILES"
fi

if [ -s "$CHANGED_FILES" ]; then
	ui_print "[*] Changed files:"
	while IFS= read -r file; do
		ui_print "    - $file"
	done < "$CHANGED_FILES"
	ui_print "[*] VOLUME UP to apply all updates, DOWN to keep current files"
	if detect_key_press; then
		apply_changed "$CONFIG_DIR" "$PERSISTENT_DIR" < "$CHANGED_FILES"
	else
		ui_print "[+] Kept existing files"
	fi
fi
rm -f "$CHANGED_FILES"

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
