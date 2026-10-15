#!/system/bin/sh
#title=Spoof settings
#author=ahmed-alnassif
#desc=Spoofs developer options, debugging states, and SELinux status

PATH=/data/adb/ksu/bin:/data/data/com.termux/files/usr/bin:$PATH

# Mirror a stock debug build: no dev options, no ADB, strict install verifier.
while read -r key value; do
	settings put global "$key" "$value" || echo "[-] settings put $key $value failed"
done <<'EOF'
development_settings_enabled	0
adb_enabled	0
adb_wifi_enabled	0
package_verifier_enable	1
verifier_verify_adb_installs	1
usb_mass_storage_enabled	0
EOF
settings delete global hidden_api_policy

if [ "$(getenforce)" != "Enforcing" ]; then
	setenforce 1 || echo "[-] setenforce 1 failed"
fi

echo "[+] settings spoofed successfully"
echo "[*] no reboot required"
