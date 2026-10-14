#!/system/bin/sh
set -eu
API=https://api.github.com/repos/inforcqb/oneplus-susfs4ksu-lkm/releases/latest
REPO=https://github.com/inforcqb/oneplus-susfs4ksu-lkm
DEST=/data/adb/loader/susfs_guard_lkm.ko
CURL=/system/bin/curl
KMI=$(ksud boot-info current-kmi 2>/dev/null) || { echo "[x] Cannot read current KMI" >&2; exit 1; }
case "$KMI" in android[0-9]*-[0-9]*.[0-9]*) ;; *) echo "[x] Invalid current KMI: $KMI" >&2; exit 1 ;; esac
case "$KMI" in *[!a-zA-Z0-9._-]*) echo "[x] Invalid current KMI" >&2; exit 1 ;; esac
NAME=susfs_guard_lkm-$KMI.ko
WORK=$(/system/bin/mktemp -d /data/local/tmp/resusfs-lkm.XXXXXX) || { echo "[x] Cannot create a private temporary directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
    attempt=1
    while [ "$attempt" -le 3 ]; do
        echo "[*] Download attempt $attempt/3: $1" >&2
        code=$("$CURL" --silent --show-error --location --connect-timeout 15 --max-time 120 --output "$2" --write-out '%{http_code}' "$1") || code=000
        case "$code" in
            2*) echo "[+] Download successful" >&2; return 0 ;;
            *) echo "[-] Download failed (HTTP $code)" >&2; rm -f "$2" ;;
        esac
        if [ "$attempt" -lt 3 ]; then /data/adb/ksu/bin/busybox sleep 3; fi
        attempt=$((attempt + 1))
    done
    echo "[!] All download attempts failed: $1" >&2
    return 1
}
if fetch "$API" "$WORK/release.json"; then
    result=$(/data/adb/ksu/bin/busybox awk -v wanted="$NAME" '
    function get(k,s,t){t=s;if(t !~ "\\\"" k "\\\"[[:space:]]*:")return "";sub(".*\\\"" k "\\\"[[:space:]]*:[[:space:]]*\\\"","",t);sub("\\\".*","",t);return t}
    /^[[:space:]]*"assets"[[:space:]]*:/ {a=1}
    a && /^[[:space:]]*\][,]?[[:space:]]*$/ {a=0}
    a && /^[[:space:]]*\{[[:space:]]*$/ {o=1;n=u=d="";next}
    o {v=get("name",$0);if(v!="")n=v;v=get("browser_download_url",$0);if(v!="")u=v;v=get("digest",$0);if(v!="")d=v}
    o && /^[[:space:]]*\}[,]?[[:space:]]*$/ {if(n==wanted){c++;U=u;D=d}o=0}
    END {if(c==1 && U ~ /^https:\/\/github[.]com\/inforcqb\/(oneplus-susfs4ksu-lkm|susfs4ksu-lkm)\/releases\/download\// && D ~ /^sha256:[0-9a-fA-F]+$/ && length(D)==71)print U " " substr(D,8)}
    ' "$WORK/release.json")
    if [ -z "$result" ]; then echo "[!] Release API has no unique exact-KMI asset digest; trying release page" >&2; fi
else
    echo "[!] GitHub Releases API unavailable/rate-limited; using latest release page (HTTP fallback)" >&2
fi
if [ -n "${result:-}" ]; then
    URL=${result%% *}; EXPECTED=${result#* }
else
    fetch "$REPO/releases/latest" "$WORK/latest.html" || { echo "[x] Cannot read latest release page" >&2; exit 1; }
    TAG=$(grep -oE "releases/tag/[A-Za-z0-9._-]+" "$WORK/latest.html" | head -n 1 | cut -d/ -f3)
    [ -n "$TAG" ] || { echo "[x] Cannot determine latest release tag" >&2; exit 1; }
    fetch "$REPO/releases/expanded_assets/$TAG" "$WORK/assets.html" || { echo "[x] Cannot read release assets" >&2; exit 1; }
    result=$(/data/adb/ksu/bin/busybox awk -v wanted="$NAME" -v tag="$TAG" '
    /<li[ >]/ { row=""; inside=1 }
    inside { row=row $0 " " }
    inside && /<\/li>/ {
        inside=0
        if (index(row, "releases/download/" tag "/" wanted)) {
            digest=row
            if (digest !~ "aria-label=\\\"Copy to clipboard digest for " wanted "\\\"") next
            sub(".*value=\\\"sha256:", "", digest)
            sub("\\\".*", "", digest)
            if (length(digest)==64 && digest !~ /[^0-9a-fA-F]/) {
                path=row
                sub(".*href=\\\"", "", path)
                sub("\\\".*", "", path)
                if (path ~ /^\/inforcqb\/(oneplus-susfs4ksu-lkm|susfs4ksu-lkm)\/releases\/download\//) {
                    count++; P=path; D=digest
                }
            }
        }
    }
    END { if(count==1) print P " " D }
    ' "$WORK/assets.html")
    [ -n "$result" ] || { echo "[x] Exact KMI asset or its SHA-256 digest is missing/ambiguous in latest release $TAG" >&2; exit 1; }
    ASSET_PATH=${result%% *}; EXPECTED=${result#* }
    URL="https://github.com$ASSET_PATH"
fi
case "$URL" in
    https://github.com/inforcqb/oneplus-susfs4ksu-lkm/releases/download/*|https://github.com/inforcqb/susfs4ksu-lkm/releases/download/*) ;;
    *) echo "[x] Unexpected download host or repository" >&2; exit 1 ;;
esac
[ -n "$EXPECTED" ] || { echo "[x] No trusted SHA-256 digest for $NAME" >&2; exit 1; }
fetch "$URL" "$WORK/$NAME" || { echo "[x] Asset download failed" >&2; exit 1; }
ACTUAL=$(/system/bin/sha256sum "$WORK/$NAME" | cut -d' ' -f1)
[ "$ACTUAL" = "$EXPECTED" ] || { echo "[x] SHA-256 mismatch" >&2; exit 1; }
if [ "${1:-}" = --dry-run ]; then echo "[+] Verified $NAME from latest release; SHA-256 $ACTUAL (dry run, not installed)"; exit 0; fi
mkdir -p "$(dirname "$DEST")"
printf '%s\n' "$KMI" > "$WORK/current-kmi"
chmod 0644 "$WORK/$NAME" "$WORK/current-kmi"
mv -f "$WORK/$NAME" "$DEST"
mv -f "$WORK/current-kmi" "$DEST.kmi"
echo "[+] Installed $NAME after HTTPS and SHA-256 verification"
