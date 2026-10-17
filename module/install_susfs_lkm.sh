#!/system/bin/sh
set -eu
API=https://api.github.com/repos/wswzgdg/susfs4ksu-lkm/releases/latest
REPO=https://github.com/wswzgdg/susfs4ksu-lkm
DEST=/data/adb/loader/susfs_guard_lkm.ko
KMI=$(ksud boot-info current-kmi 2>/dev/null) || { echo "[x] Cannot read current KMI" >&2; exit 1; }
case "$KMI" in android[0-9]*-[0-9]*.[0-9]*) ;; *) echo "[x] Invalid current KMI: $KMI" >&2; exit 1 ;; esac
case "$KMI" in *[!a-zA-Z0-9._-]*) echo "[x] Invalid current KMI" >&2; exit 1 ;; esac
NAME=susfs_guard_lkm-$KMI.ko.gz
# Skip download if the .ko is already installed, loaded, and matches the current KMI
if [ -f "$DEST" ] && [ -f "$DEST.kmi" ] && [ "$(cat "$DEST.kmi" 2>/dev/null)" = "$KMI" ] && [ -d /sys/module/susfs_guard_lkm ]; then
    echo "[+] LKM already installed for $KMI and loaded; skipping download"
    exit 0
fi
WORK=$(/system/bin/mktemp -d /data/local/tmp/resusfs-lkm.XXXXXX) || { echo "[x] Cannot create a private temporary directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# download_file() lives in utils.sh. PATH is restored right after sourcing so the
# tools this script calls keep resolving to the same binaries.
[ -n "${MODPATH:-}" ] || MODPATH="$(cd "$(dirname "$0")" && pwd)"
PATH_BEFORE="$PATH"
. "$MODPATH/utils.sh"
PATH="$PATH_BEFORE"
download_file "$REPO/releases/latest" "$WORK/latest.html" || { echo "[x] Cannot read latest release page" >&2; exit 1; }
TAG=$(grep -oE "releases/tag/[A-Za-z0-9._-]+" "$WORK/latest.html" | head -n 1 | cut -d/ -f3)
[ -n "$TAG" ] || { echo "[x] Cannot determine latest release tag" >&2; exit 1; }
download_file "$REPO/releases/expanded_assets/$TAG" "$WORK/assets.html" || { echo "[x] Cannot read release assets" >&2; exit 1; }
result=$(/data/adb/ksu/bin/busybox awk -v wanted="$NAME" -v tag="$TAG" '
/<li[ >]/ { row=""; inside=1 }
inside { row=row $0 " " }
inside && /<\/li>/ {
    inside=0
    if (index(row, "releases/download/" tag "/" wanted)) {
        digest=row
        if (digest !~ "aria-label=\042Copy to clipboard digest for " wanted "\042") next
        sub(".*value=\042sha256:", "", digest)
        sub("\042.*", "", digest)
        if (length(digest)==64 && digest !~ /[^0-9a-fA-F]/) {
            path=row
            sub(".*href=\042", "", path)
            sub("\042.*", "", path)
            if (path ~ /^\/wswzgdg\/susfs4ksu-lkm\/releases\/download\//) {
                count++; P=path; D=digest
            }
        }
    }
}
END { if(count==1) print P " " D }
' "$WORK/assets.html")
if [ -n "$result" ]; then
    ASSET_PATH=${result%% *}; EXPECTED=${result#* }
    URL="https://github.com$ASSET_PATH"
else
    echo "[!] Release page has no unique exact-KMI asset digest; trying GitHub API" >&2
    if download_file "$API" "$WORK/release.json"; then
        result=$(/data/adb/ksu/bin/busybox awk -v wanted="$NAME" '
        function get(k,s,t){t=s;if(t !~ "\042" k "\042[[:space:]]*:")return "";sub(".*\042" k "\042[[:space:]]*:[[:space:]]*\\042", "",t);sub("\042.*","",t);return t}
        /^[[:space:]]*"assets"[[:space:]]*:/ {a=1}
        a && /^[[:space:]]*\][,]?[[:space:]]*$/ {a=0}
        a && /^[[:space:]]*\{[[:space:]]*$/ {o=1;n=u=d="";next}
        o {v=get("name",$0);if(v!="")n=v;v=get("browser_download_url",$0);if(v!="")u=v;v=get("digest",$0);if(v!="")d=v}
        o && /^[[:space:]]*\}[,]?[[:space:]]*$/ {if(n==wanted){c++;U=u;D=d}o=0}
        END {if(c==1 && U ~ /^https:\/\/github[.]com\/wswzgdg\/susfs4ksu-lkm\/releases\/download\// && D ~ /^sha256:[0-9a-fA-F]+$/ && length(D)==71)print U " " substr(D,8)}
        ' "$WORK/release.json")
        [ -n "$result" ] || { echo "[x] Cannot find exact-KMI asset with digest in GitHub API" >&2; exit 1; }
        URL=${result%% *}; EXPECTED=${result#* }
    else
        echo "[x] Cannot read GitHub Releases API" >&2
        exit 1
    fi
fi
case "$URL" in
    https://github.com/wswzgdg/susfs4ksu-lkm/releases/download/*) ;;
    *) echo "[x] Unexpected download host or repository" >&2; exit 1 ;;
esac
[ -n "$EXPECTED" ] || { echo "[x] No trusted SHA-256 digest for $NAME" >&2; exit 1; }
# Try multiple download URLs: direct GitHub, then mirrors (for slow/blocked connections)
MIRRORS="
$URL
https://ghproxy.com/$URL
https://mirror.ghproxy.com/$URL
https://gh.llkk.cc/$URL
"
DOWNLOADED=false
for URL_TRY in $MIRRORS; do
    echo "[*] Trying: $URL_TRY"
    if download_file "$URL_TRY" "$WORK/$NAME"; then
        ACTUAL=$(/system/bin/sha256sum "$WORK/$NAME" | cut -d' ' -f1)
        if [ "$ACTUAL" = "$EXPECTED" ]; then
            DOWNLOADED=true
            break
        fi
        echo "[!] SHA-256 mismatch from $URL_TRY, trying next mirror" >&2
        rm -f "$WORK/$NAME"
    fi
done
[ "$DOWNLOADED" = true ] || { echo "[x] All download attempts failed" >&2; exit 1; }
if [ "${1:-}" = --dry-run ]; then echo "[+] Verified $NAME from latest release; SHA-256 $ACTUAL (dry run, not installed)"; exit 0; fi
mkdir -p "$(dirname "$DEST")"
printf '%s\n' "$KMI" > "$WORK/current-kmi"
# decompress .ko.gz -> .ko, verify the inner file exists
/system/bin/gzip -dc "$WORK/$NAME" > "$WORK/${NAME%.gz}" || { echo "[x] gzip decompress failed" >&2; exit 1; }
[ -s "$WORK/${NAME%.gz}" ] || { echo "[x] Decompressed .ko is empty" >&2; exit 1; }
chmod 0644 "$WORK/${NAME%.gz}" "$WORK/current-kmi"
mv -f "$WORK/${NAME%.gz}" "$DEST"
mv -f "$WORK/current-kmi" "$DEST.kmi"
echo "[+] Installed ${NAME%.gz} after HTTPS and SHA-256 verification"
