#!/usr/bin/env bash
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Preflight ---

if ! command -v archinstall >/dev/null 2>&1; then
  echo "archinstall not found. Boot the official Arch ISO." >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found. Run: pacman -Sy openssl" >&2
  exit 1
fi

if ! curl -fsS --connect-timeout 5 https://archlinux.org >/dev/null 2>&1; then
  echo "No internet connection. Connect first:" >&2
  echo "  iwctl station wlan0 connect YOUR_SSID" >&2
  echo "  # or: ethernet should connect automatically" >&2
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Disk $DISK not found. Block devices:" >&2
  lsblk -o NAME,PATH,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINTS >&2
  exit 1
fi

# Detect CPU vendor for microcode
UCODE=""
if grep -q "^vendor_id.*GenuineIntel" /proc/cpuinfo 2>/dev/null; then
  UCODE="intel-ucode"
elif grep -q "^vendor_id.*AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
  UCODE="amd-ucode"
fi

VERSION=$(archinstall --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true)
MAJOR=${VERSION%%.*}

if [[ "$MAJOR" == "2" ]]; then
  TEMPLATE="archinstall-2x.json"
else
  TEMPLATE="archinstall-3x.json"
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Missing $TEMPLATE" >&2
  exit 1
fi

# --- Prompts ---

read -rp "Hostname: " HOSTNAME
if [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
  echo "Invalid hostname." >&2
  exit 1
fi

read -rp "Linux username to create: " USERNAME
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid username." >&2
  exit 1
fi

read -rsp "LUKS passphrase: " LUKS_PASSWORD_1; echo
read -rsp "Repeat LUKS passphrase: " LUKS_PASSWORD_2; echo
if [[ "$LUKS_PASSWORD_1" != "$LUKS_PASSWORD_2" ]]; then
  echo "LUKS passphrases do not match." >&2
  exit 1
fi

read -rsp "Password for user '$USERNAME': " USER_PASSWORD_1; echo
read -rsp "Repeat user password: " USER_PASSWORD_2; echo
if [[ "$USER_PASSWORD_1" != "$USER_PASSWORD_2" ]]; then
  echo "User passwords do not match." >&2
  exit 1
fi

echo
echo "Locale:   en_US.UTF-8"
echo "Timezone: Europe/Warsaw"
read -rp "Use these defaults? [Y/n] " LOCALE_OK
if [[ "${LOCALE_OK,,}" == "n" ]]; then
  read -rp "Locale (e.g. en_US.UTF-8, pl_PL.UTF-8): " SYS_LANG
  read -rp "Timezone (e.g. Europe/Warsaw, America/New_York): " TIMEZONE
  if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    echo "Invalid timezone: $TIMEZONE" >&2
    exit 1
  fi
else
  SYS_LANG="en_US.UTF-8"
  TIMEZONE="Europe/Warsaw"
fi

# --- Generate configs ---

umask 077

USER_HASH=$(printf '%s' "$USER_PASSWORD_1" | openssl passwd -6 -stdin)

USERNAME="$USERNAME" USER_HASH="$USER_HASH" LUKS_PASSWORD="$LUKS_PASSWORD_1" python - <<'PY' > user_credentials.json
import json, os
creds = {
    "!encryption-password": os.environ["LUKS_PASSWORD"],
    "users": [{
        "username": os.environ["USERNAME"],
        "enc_password": os.environ["USER_HASH"],
        "sudo": True,
    }],
}
print(json.dumps(creds, indent=2))
PY
chmod 600 user_credentials.json

unset LUKS_PASSWORD_1 LUKS_PASSWORD_2 USER_PASSWORD_1 USER_PASSWORD_2 USER_HASH

sed -e "s#/dev/nvme0n1#$DISK#g" \
    -e "s#\"hostname\": \"archlinux\"#\"hostname\": \"$HOSTNAME\"#g" \
    -e "s#\"sys_lang\": \"en_US.UTF-8\"#\"sys_lang\": \"$SYS_LANG\"#g" \
    -e "s#\"timezone\": \"Europe/Warsaw\"#\"timezone\": \"$TIMEZONE\"#g" \
    "$TEMPLATE" > user_configuration.json

if [[ -n "$UCODE" ]]; then
  sed -i "s#\"__UCODE__\"#\"$UCODE\"#g" user_configuration.json
else
  sed -i '/"__UCODE__"/d' user_configuration.json
fi

# --- Confirm and install ---

echo
echo "=== Arch Linux LUKS Install ==="
echo "Hostname:    $HOSTNAME"
echo "User:        $USERNAME"
echo "Disk:        $DISK"
echo "Config:      $TEMPLATE (archinstall $VERSION)"
echo "Locale:      $SYS_LANG"
echo "Timezone:    $TIMEZONE"
echo "Microcode:   ${UCODE:-none}"
echo "Filesystem:  btrfs + LUKS2"
echo "Subvolumes:  @ (/) | @home (/home) | @var (/var)"
echo
echo "This will WIPE $DISK. Current layout:"
lsblk -o NAME,PATH,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINTS "$DISK"
echo
read -rp "Type exactly WIPE-$DISK to continue: " CONFIRM
if [[ "$CONFIRM" != "WIPE-$DISK" ]]; then
  echo "Aborted."
  exit 1
fi

echo
echo "Running archinstall dry-run..."
archinstall --config user_configuration.json --creds user_credentials.json --dry-run

echo
read -rp "Dry-run finished. Type INSTALL to proceed: " GO
if [[ "$GO" != "INSTALL" ]]; then
  echo "Aborted after dry-run."
  exit 1
fi

archinstall --config user_configuration.json --creds user_credentials.json
