#!/bin/sh
PATH=/data/adb/ksu/bin:/data/data/com.termux/files/usr/bin:$PATH
MODDIR="/data/adb/modules/ReSuSFS"
PERSISTENT_DIR="/data/adb/ReSuSFS"
USER_SCRIPTS_DIR="$PERSISTENT_DIR/scripts"
POSTFS_SCRIPTS_FILE="$PERSISTENT_DIR/scripts_postfs.txt"
BOOTCOMPLETED_SCRIPTS_FILE="$PERSISTENT_DIR/scripts_bootcompleted.txt"
CRON_SCRIPTS_FILE="$PERSISTENT_DIR/scripts_cron.txt"
CROND_DIR="$PERSISTENT_DIR/crontabs"
SUSFS_BIN=/data/adb/ksu/bin/ksu_susfs
SUSFS_MIN_VERSION="v2.2.0"
LKM_ASSET=/data/adb/loader/susfs_guard_lkm.ko

. "$MODDIR/utils.sh"

[ -n "$WEBUI_QUIET" ] && [ "${NO_BANNER:-0}" = "0" ] && banner

lkm_enabled() { [ -f "$PERSISTENT_DIR/lkm_enabled" ] && [ "$(cat "$PERSISTENT_DIR/lkm_enabled" 2>/dev/null)" = 1 ]; }
lkm_loaded() { [ -d /sys/module/susfs_guard_lkm ]; }

# Prints why the LKM asset cannot be used and returns 1; 0 means it is usable.
# Also sets current_kmi, for callers that want to show it.
check_lkm_asset() {
	[ -f "$LKM_ASSET" ] || { echo "[x] LKM asset is missing; install it first"; return 1; }
	current_kmi=$(ksud boot-info current-kmi 2>/dev/null) || { echo "[x] Cannot determine current KMI"; return 1; }
	[ "$(cat "$LKM_ASSET".kmi 2>/dev/null)" = "$current_kmi" ] || { echo "[x] LKM asset KMI does not match current KMI $current_kmi; download/update it first"; return 1; }
}
# Loads the LKM now if it is not loaded yet. Called right after install so the
# module does not need a reboot, and by stage_early so it is loaded on boot.
load_lkm() {
	if lkm_loaded; then
		echo "[+] SUSFS LKM already loaded"
		return 0
	fi
	check_lkm_asset || return 1
	ksud insmod "$LKM_ASSET" || { echo "[x] SUSFS LKM load failed"; return 1; }
	echo "[+] SUSFS LKM loaded"
}
susfs() {
    if [ -x "$SUSFS_BIN" ]; then
        if "$SUSFS_BIN" "$@"; then return 0; else rc=$?; fi
        lkm_loaded || return "$rc"
    fi
    lkm_loaded || { echo "[x] LKM is not loaded"; return 1; }
    case "$1" in
        add_sus_kstat|add_sus_kstat_statically|update_sus_kstat|update_sus_kstat_full_clone)
            command="$1"; shift
            { printf '%s' "$command"; for arg do printf ' %s' "$arg"; done; printf '\n'; } > /proc/susfs_kstat ;;
        del_sus_kstat) printf 'del %s\n' "$2" > /proc/susfs_kstat ;;
        clear_sus_kstat) printf 'clear\n' > /proc/susfs_kstat ;;

        add_sus_path) printf 'add %s\n' "$2" > /proc/susfs_path ;;
        del_sus_path) printf 'del %s\n' "$2" > /proc/susfs_path ;;
        clear_sus_paths) printf 'clear\n' > /proc/susfs_path ;;
        add_open_redirect) printf 'add_open_redirect %s %s %s\n' "$2" "$3" "$4" > /proc/susfs_open_redirect ;;
        del_open_redirect) printf 'del %s\n' "$2" > /proc/susfs_open_redirect ;;
        clear_open_redirect) printf 'clear\n' > /proc/susfs_open_redirect ;;
        enable_log) printf '%s\n' "$2" > /proc/susfs_enable_log ;;
        enable_avc_log_spoofing) printf '%s\n' "$2" > /proc/susfs_avc_spoof ;;
        add_hide_modules) printf 'add %s\n' "$2" > /proc/susfs_hide_modules ;;
        del_hide_modules) printf 'del %s\n' "$2" > /proc/susfs_hide_modules ;;
        clear_hide_modules) printf 'clear\n' > /proc/susfs_hide_modules ;;
        set_hide_modules) printf 'set %s\n' "$2" > /proc/susfs_hide_modules ;;
        hide_sus_mnts_for_non_su_procs)
            case "$2" in 0) printf 'disable\n' > /proc/susfs_hide_mounts ;; 1) printf 'enable\n' > /proc/susfs_hide_mounts ;; *) echo "[x] Expected 0 or 1 for mount hiding" >&2; return 1 ;; esac ;;
        add_sus_path_loop|add_sus_map|set_uname|set_cmdline_or_bootconfig|show)
            [ -x "$SUSFS_BIN" ] || { echo "[x] ksu_susfs CLI is required for $1" >&2; return 1; }
            "$SUSFS_BIN" "$@" ;;
        *) echo "[x] Unsupported by SUSFS LKM: $1"; return 1 ;;
    esac
}

version_ge() {
	[ "$1" = "$2" ] && return 0
	# Strip leading 'v' and compare numerically
	awk -v v1="${1#v}" -v v2="${2#v}" 'BEGIN {
		n1 = split(v1, a, "."); n2 = split(v2, b, ".");
		for (i = 1; i <= (n1 > n2 ? n1 : n2); i++) {
			x = a[i] + 0; y = b[i] + 0;
			if (x > y) exit 0;
			if (x < y) exit 1;
		}
		exit 0
	}'
}

get_conf() {
	file="${3:-$PERSISTENT_DIR/config.txt}"
	val=$(grep "^$1=" "$file" 2>/dev/null | tail -n1 | cut -d'=' -f2-)
	[ -z "$val" ] && val="$2"
	echo "$val"
}

read_list() {
	[ -f "$1" ] || return
	sed 's/#.*//' "$1" | grep -v '^[[:space:]]*$'
}

# Rewrite $1 in place with duplicate lines removed, keeping comments.
# $2 = 1 also drops blank lines.
dedupe_file() {
	file="$1"
	[ -f "$file" ] || return 0
	tmp="${file}.tmp.$$"
	busybox awk -v skip_blank="$2" '
		/^[[:space:]]*#/ { print; next }
		skip_blank == "1" && /^[[:space:]]*$/ { next }
		!seen[$0]++
	' "$file" > "$tmp" && cat "$tmp" > "$file"
	rm -f "$tmp"
}

# Validate a config input file: .txt extension, exists, readable, non-empty.
check_txt_input() {
	case "$1" in
		*.txt) : ;;
		*) echo "[x] only .txt files allowed: $1"; return 1 ;;
	esac
	[ -f "$1" ] || { echo "[x] file not found: $1"; return 1; }
	[ -r "$1" ] || { echo "[x] file not readable: $1"; return 1; }
	[ -s "$1" ] || { echo "[x] file empty: $1"; return 1; }
}

[ ! -d "$USER_SCRIPTS_DIR" ] && mkdir -p "$USER_SCRIPTS_DIR"
[ ! -f "$POSTFS_SCRIPTS_FILE" ] && : > "$POSTFS_SCRIPTS_FILE"
[ ! -f "$BOOTCOMPLETED_SCRIPTS_FILE" ] && : > "$BOOTCOMPLETED_SCRIPTS_FILE"

[ ! -f "$CRON_SCRIPTS_FILE" ] && : > "$CRON_SCRIPTS_FILE"

run_stage_scripts() {
	stage_file="$1"
	[ -f "$stage_file" ] || return
	list=$(read_list "$stage_file") || return
	[ -z "$list" ] && return
	echo "$list" | while IFS= read -r name; do
		case "$name" in
			"!"*) continue ;;
		esac
		script="$USER_SCRIPTS_DIR/$name"
		if [ -f "$script" ]; then
			echo "[>] running $script"
			sh "$script"
		else
			echo "[!] script not found, skipping: $name"
		fi
	done
}

sync_cron_scripts() {
	[ ! -d "$CROND_DIR" ] && mkdir -p "$CROND_DIR"

	pkill -f "busybox crond -bc $CROND_DIR" 2>/dev/null
	sleep 1

	busybox crond -bc "$CROND_DIR" -L /dev/null

	tmp="${CROND_DIR}/root.tmp.$$"
	: > "$tmp"

	list=$(read_list "$CRON_SCRIPTS_FILE") || { rm -f "$tmp"; return; }
	echo "$list" | while IFS= read -r line; do
		schedule=$(echo "$line" | cut -d' ' -f1-5)
		name=$(echo "$line" | cut -d' ' -f6-)
		[ -z "$name" ] && continue
		[ -f "$USER_SCRIPTS_DIR/$name" ] || { echo "[!] cron script not found, skipping: $name"; continue; }
		echo "$schedule { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] START $name\"; sh $MODDIR/ReSuSFS.sh --run-script $USER_SCRIPTS_DIR/$name; echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] END $name exit=\$?\"; } >> $PERSISTENT_DIR/cron.log 2>&1" >> "$tmp"
	done

	busybox crontab -c "$CROND_DIR" "$tmp" 2>/dev/null || { rm -f "$tmp"; echo "[-] failed to install cron schedule"; return 1; }
	rm -f "$tmp"

	echo "[+] cron schedule synced"
}

run_script() {
	script="$1"
	[ -z "$script" ] && { echo "[x] no script specified"; echo "[!] syntax: --run-script <path>"; return 1; }
	case "$script" in
		*.sh) : ;;
		*) echo "[x] only .sh files allowed: $script"; return 1 ;;
	esac
	[ -f "$script" ] || { echo "[x] script not found: $script"; return 1; }
	[ -r "$script" ] || { echo "[x] script not readable: $script"; return 1; }
	echo "[>] running $script"
	sh "$script"
	rc=$?
	echo "[*] exit code: $rc"
	return "$rc"
}

apply_list() {
	default="$1"; cmd="$2"; mode="$3"; file="${4:-$default}"

	dedupe_file "$file" 1

	list=$(read_list "$file") || return
	[ -z "$list" ] && return
	echo "$list" | while IFS= read -r p; do
		if [ "$mode" = "1" ] && [ ! -e "$p" ]; then echo "[!] skip missing path: $p"; continue; fi
		if [ "$mode" = "2" ] && [ ! -e "$p" ]; then continue; fi
		echo "[>] $cmd $p"
		susfs "$cmd" "$p"
	done
}

append_to_default() {
	default="$1"
	src="${2:-$default}"
	[ "$src" = "$default" ] && return 0
	check_txt_input "$src" || return 1

	cat "$src" >> "$default"

	dedupe_file "$default" 0

	echo "[>] appended $src -> $default"
}

apply_sus_paths() { [ -n "$1" ] && { append_to_default "$PERSISTENT_DIR/sus_paths.txt" "$1" || return 1; }; apply_list "$PERSISTENT_DIR/sus_paths.txt" add_sus_path 1; }
apply_sus_paths_loop() { [ -n "$1" ] && { append_to_default "$PERSISTENT_DIR/sus_paths_loop.txt" "$1" || return 1; }; apply_list "$PERSISTENT_DIR/sus_paths_loop.txt" add_sus_path_loop 0; }
apply_sus_maps() { [ -n "$1" ] && { append_to_default "$PERSISTENT_DIR/sus_maps.txt" "$1" || return 1; }; apply_list "$PERSISTENT_DIR/sus_maps.txt" add_sus_map 1; }

apply_kstat() {
	mode="$1"
	[ -n "$2" ] && { append_to_default "$PERSISTENT_DIR/kstat_paths.txt" "$2" || return 1; }
	file="$PERSISTENT_DIR/kstat_paths.txt"
	list=$(read_list "$file") || return
	[ -z "$list" ] && return
	echo "$list" | while IFS= read -r line; do
		# split the line once instead of forking awk + cut; globbing off so paths with * survive
		set -f
		# shellcheck disable=SC2086
		set -- $line
		set +f
		path="$1"
		[ -z "$path" ] && continue
		shift
		case "$mode" in
			add)
				if [ $# -gt 0 ]; then
					echo "[>] add_sus_kstat_statically $path $*"
					susfs add_sus_kstat_statically "$path" "$@"
				else
					echo "[>] add_sus_kstat $path"
					susfs add_sus_kstat "$path"
				fi
				;;
			update)
				echo "[>] update_sus_kstat $path"
				susfs update_sus_kstat "$path"
				;;
		esac
	done
}

apply_kstat_add() { apply_kstat add "$1"; }
apply_kstat_update() { apply_kstat update "$1"; }

apply_open_redirect() {
	[ -n "$1" ] && { append_to_default "$PERSISTENT_DIR/open_redirect.txt" "$1" || return 1; }
	file="$PERSISTENT_DIR/open_redirect.txt"
	list=$(read_list "$file") || return
	[ -z "$list" ] && return
	echo "$list" | while IFS= read -r line; do
		# one word-split instead of three awk passes; globbing off so paths with * survive
		set -f
		# shellcheck disable=SC2086
		set -- $line
		set +f
		target="$1"
		redirect="$2"
		scheme="$3"
		if [ -z "$target" ] || [ -z "$redirect" ] || [ -z "$scheme" ]; then continue; fi
		[ -e "$target" ] && [ -e "$redirect" ] || { echo "[!] skip: $target -> $redirect (missing endpoint)"; continue; }
		echo "[>] add_open_redirect $target -> $redirect (scheme $scheme)"
		susfs add_open_redirect "$target" "$redirect" "$scheme"
	done
}



# Read release= and version= from $1 into release/version; 1 if either is missing.
read_uname_conf() {
	release=$(get_conf release "" "$1")
	version=$(get_conf version "" "$1")
	[ -n "$release" ] || { echo "[x] release missing in $1"; return 1; }
	[ -n "$version" ] || { echo "[x] version missing in $1"; return 1; }
}

apply_uname() {
	[ -n "$1" ] && {
		check_txt_input "$1" || return 1

		# Validate the incoming pair before rewriting the persisted one.
		read_uname_conf "$1" || return 1

		tmp="${PERSISTENT_DIR}/uname.txt.tmp.$$"
		if [ -f "$PERSISTENT_DIR/uname.txt" ]; then
			grep -vE '^(release|version)=' "$PERSISTENT_DIR/uname.txt" > "$tmp"
		else
			: > "$tmp"
		fi
		printf 'release=%s\nversion=%s\n' "$release" "$version" >> "$tmp"
		cat "$tmp" > "$PERSISTENT_DIR/uname.txt"
		rm -f "$tmp"
	}

	file="$PERSISTENT_DIR/uname.txt"
	[ -f "$file" ] || return

	read_uname_conf "$file" || return 1

	echo "[>] set_uname '$release' '$version'"
	susfs set_uname "$release" "$version"
}

apply_cmdline_bootconfig() {
	[ -n "$1" ] && { append_to_default "$PERSISTENT_DIR/cmdline_or_bootconfig.txt" "$1" || return 1; }
	file="$PERSISTENT_DIR/cmdline_or_bootconfig.txt"
	[ -s "$file" ] || return
	echo "[>] set_cmdline_or_bootconfig $file"
	susfs set_cmdline_or_bootconfig "$file"
}

update_module_description() {
	new_description="$1"
	module_prop="$MODDIR/module.prop"
	[ -f "$module_prop" ] || return 1
	current_description=$(sed -n 's/^description=//p' "$module_prop")
	[ "$current_description" = "$new_description" ] && return 0
	tmp_prop="$module_prop.tmp.$$"
	if ! awk -v description="$new_description" '
		BEGIN { updated = 0 }
		/^description=/ { print "description=" description; updated = 1; next }
		{ print }
		END { if (!updated) exit 1 }
	' "$module_prop" > "$tmp_prop"; then
		rm -f "$tmp_prop"
		return 1
	fi
	chmod --reference="$module_prop" "$tmp_prop" 2>/dev/null || chmod 0644 "$tmp_prop"
	chown --reference="$module_prop" "$tmp_prop" 2>/dev/null || true
	mv -f "$tmp_prop" "$module_prop"
}

lkm_interfaces() {
	for node in /proc/susfs_*; do
		[ -e "$node" ] && printf '%s\n' "${node##*/}"
	done
}

status_report() {
	if [ -f "$MODDIR/disable" ]; then
		echo "[*] not running since module has been disabled"
		update_module_description "status: disabled ❌"
		return
	fi

	if [ ! -x "$SUSFS_BIN" ]; then
		if lkm_loaded; then
			ifaces=$(lkm_interfaces)
			msg="status: SUSFS LKM active; interfaces: ${ifaces:-none}; supercall CLI missing"
			update_module_description "$msg"
			echo "[+] $msg"
			return
		fi
		echo "[x] ksu_susfs binary not found at $SUSFS_BIN 😭"
		echo "[x] this kernel does not expose susfs, or susfs userspace tool is missing"
		update_module_description "status: susfs binary not found 😭 needs correction 💢"
		return
	fi

	susfs_version=$(susfs show version 2>/dev/null)
	if [ -z "$susfs_version" ] || ! version_ge "$susfs_version" "$SUSFS_MIN_VERSION"; then
		if lkm_loaded; then
			ifaces=$(lkm_interfaces)
			msg="status: SUSFS LKM active; interfaces: ${ifaces:-none}; native version metadata unavailable"
			update_module_description "$msg"
			echo "[+] $msg"
			return
		fi
		echo "[x] unsupported susfs version: '$susfs_version' 😭"
		echo "[x] need $SUSFS_MIN_VERSION or higher"
		update_module_description "status: unsupported susfs $susfs_version ❌ | need $SUSFS_MIN_VERSION+"
		return
	fi

	feat=$(susfs show enabled_features 2>/dev/null | wc -l)
	variant=$(susfs show variant 2>/dev/null)
	update_module_description "status: active ✅ | susfs $susfs_version ($variant) | features: $feat 🧩"
	echo "[+] $susfs_version | $variant | features: $feat"
}

# Apply one toggle; suffix is only for the log line.
set_toggle() {
	cmd="$1"; value="$2"; suffix="${3:-}"
	[ -n "$value" ] || return
	echo "[>] $cmd $value$suffix"
	susfs "$cmd" "$value" || echo "[!] $cmd toggle ignored"
}

apply_toggles() {
	stage="$1"
	file="${2:-$PERSISTENT_DIR/config.txt}"
	[ -f "$file" ] || return

	hide_mnts=$(get_conf HIDE_SUS_MNTS_NON_SU "" "$file")
	enable_log=$(get_conf ENABLE_LOG "" "$file")
	avc_spoof=$(get_conf ENABLE_AVC_LOG_SPOOFING "" "$file")

	if [ "$stage" = "early" ]; then
		set_toggle hide_sus_mnts_for_non_su_procs "$hide_mnts" " (early)"
		set_toggle enable_log "$enable_log"
		set_toggle enable_avc_log_spoofing "$avc_spoof"
	else
		set_toggle hide_sus_mnts_for_non_su_procs "$hide_mnts" " (late)"
	fi
}

stage_early() {
	echo "[+] stage: early (post-fs-data)"
	if lkm_enabled && ! load_lkm; then return 1; fi
	if [ ! -x "$SUSFS_BIN" ] && ! lkm_loaded; then echo "[x] neither SUSFS CLI nor loaded LKM is available; skipping SUSFS rules"; return 1; fi
	apply_kstat_add
	if [ -x "$SUSFS_BIN" ]; then
		apply_uname
		apply_cmdline_bootconfig
		apply_open_redirect
	else
		echo "[!] ksu_susfs CLI missing; uname, cmdline spoof and open_redirect rules are skipped"
	fi
	apply_toggles early
}

stage_late() {
	echo "[+] stage: late (boot-completed)"
	if [ -x "$SUSFS_BIN" ]; then
		apply_sus_paths
		apply_sus_paths_loop
		apply_sus_maps
	else
		echo "[!] ksu_susfs CLI missing; sus_paths, sus_path_loop and sus_map rules are skipped"
	fi
	apply_kstat_update
	apply_toggles late
	sync_cron_scripts
	status_report
}

run() {
	stage_early
	stage_late
}

show_status() {
	if lkm_loaded && [ ! -x "$SUSFS_BIN" ]; then
		echo "SUSFS LKM active; version and feature metadata unavailable"
		ifaces=$(lkm_interfaces)
		[ -n "$ifaces" ] && echo "Available interfaces: $ifaces"
		return 0
	fi
	susfs show version
	susfs show variant
	susfs show enabled_features
}

show_help () {
	banner
	echo "[%] $( grep '^description=' $MODDIR/module.prop | sed 's/description=//' )"
	echo "usage:"
	printf " --action \t\t\t\tfull apply (early+late stage)\n"
	printf " --stage-early \t\t\t\tpost-fs-data stage only\n"
	printf " --stage-late \t\t\t\tboot-completed stage only\n"
	printf " --status \t\t\t\tshow susfs version / variant / enabled features\n"
	printf " --status-report \t\t\tsilently refresh module.prop's live status line\n"
	printf "\n"
	printf "if [file] is given it is appended (deduped) into the default list, then applied:\n"
	printf " --apply-sus-paths [file] \t\tadd_sus_path from list\n"
	printf " --apply-sus-paths-loop [file] \t\tadd_sus_path_loop from list\n"
	printf " --apply-sus-maps [file] \t\tadd_sus_map from list\n"
	printf " --apply-kstat-add [file] \t\tstage add_sus_kstat from list\n"
	printf " --apply-kstat-update [file] \t\tcommit update_sus_kstat from list\n"
	printf " --apply-open-redirect [file] \t\tadd_open_redirect from list\n"
	printf " --apply-uname [file] \t\t\tset_uname from config\n"
	printf " --apply-cmdline-bootconfig [file] \tset_cmdline_or_bootconfig from file\n"
	printf " --apply-toggles <early|late> [file] \tapply hide_sus_mnts/enable_log/avc_log_spoofing from config\n"
	printf " --run-script <file> \t\t\trun a user script from UserHub\n"
	printf " --run-postfs-scripts \t\t\trun all UserHub scripts flagged for post-fs-data\n"
	printf " --run-bootcompleted-scripts \t\trun all UserHub scripts flagged for boot-completed\n"
	printf " --sync-cron-scripts \t\t\trebuild the cron schedule from scripts_cron.txt\n"
	printf "\n"
	printf " --help \t\t\t\tdisplays this message\n"
}

case "$1" in
	--action) run; exit ;;
	--stage-early) stage_early; exit ;;
	--stage-late) stage_late; exit ;;
	--status) show_status; exit ;;
	--status-report) status_report; exit ;;
	--lkm-install) sh "$MODDIR/install_susfs_lkm.sh" && load_lkm; exit $? ;;
	--lkm-load) load_lkm; exit $? ;;
	--lkm-enable) check_lkm_asset || exit 1; mkdir -p "$PERSISTENT_DIR"; echo 1 > "$PERSISTENT_DIR/lkm_enabled" && load_lkm; exit $? ;;
	--lkm-disable) rm -f "$PERSISTENT_DIR/lkm_enabled"; echo "[+] LKM disabled for next boot"; exit ;;
	--apply-sus-paths) apply_sus_paths "$2"; exit ;;
	--apply-sus-paths-loop) apply_sus_paths_loop "$2"; exit ;;
	--apply-sus-maps) apply_sus_maps "$2"; exit ;;
	--apply-kstat-add) apply_kstat_add "$2"; exit ;;
	--apply-kstat-update) apply_kstat_update "$2"; exit ;;
	--apply-open-redirect) apply_open_redirect "$2"; exit ;;
	--apply-uname) apply_uname "$2"; exit ;;
	--apply-cmdline-bootconfig) apply_cmdline_bootconfig "$2"; exit ;;
	--apply-toggles) apply_toggles "$2" "$3"; exit ;;
	--hide-modules-add) susfs add_hide_modules "$2"; exit $? ;;
	--hide-modules-del) susfs del_hide_modules "$2"; exit $? ;;
	--hide-modules-clear) susfs clear_hide_modules; exit $? ;;
	--run-script) shift; run_script "$1"; exit $? ;;
	--run-postfs-scripts) run_stage_scripts "$POSTFS_SCRIPTS_FILE"; exit ;;
	--run-bootcompleted-scripts) run_stage_scripts "$BOOTCOMPLETED_SCRIPTS_FILE"; exit ;;
	--sync-cron-scripts) sync_cron_scripts; exit ;;
	--help|*) show_help; exit ;;
esac

# EOF
