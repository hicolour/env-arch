#!/usr/bin/env bash
set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"

# --- Helpers ---

part() {
  local n="$1"
  if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
    echo "${DISK}p${n}"
  else
    echo "${DISK}${n}"
  fi
}

# --- Preflight ---

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

if ! curl -fsS --connect-timeout 5 https://archlinux.org >/dev/null 2>&1; then
  echo "No internet connection. Connect first:" >&2
  echo "  iwctl --passphrase 'PASS' station wlan0 connect SSID" >&2
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

# --- Prompts ---

read -rp "Hostname: " HOSTNAME
if [[ ! "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
  echo "Invalid hostname." >&2
  exit 1
fi

read -rp "Username: " USERNAME
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid username." >&2
  exit 1
fi

read -rsp "LUKS passphrase: " LUKS_PASS; echo
read -rsp "Repeat LUKS passphrase: " LUKS_PASS2; echo
if [[ "$LUKS_PASS" != "$LUKS_PASS2" ]]; then
  echo "LUKS passphrases do not match." >&2
  exit 1
fi

read -rsp "Password for user '$USERNAME': " USER_PASS; echo
read -rsp "Repeat user password: " USER_PASS2; echo
if [[ "$USER_PASS" != "$USER_PASS2" ]]; then
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

# --- Confirm ---

PART_BOOT=$(part 1)
PART_ROOT=$(part 2)

echo
echo "=== Arch Linux LUKS Install ==="
echo "Hostname:    $HOSTNAME"
echo "User:        $USERNAME"
echo "Disk:        $DISK"
echo "  Boot:      $PART_BOOT (1 GiB FAT32 ESP)"
echo "  Root:      $PART_ROOT (rest, LUKS2 + btrfs)"
echo "Locale:      $SYS_LANG"
echo "Timezone:    $TIMEZONE"
echo "Microcode:   ${UCODE:-none}"
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

# --- Partition ---

echo
echo "Partitioning $DISK..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:ESP "$DISK"
sgdisk -n 2:0:0   -t 2:8309 -c 2:cryptroot "$DISK"
partprobe "$DISK"
sleep 1

# --- LUKS ---

echo
echo "Setting up LUKS2 on $PART_ROOT..."
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$PART_ROOT" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$PART_ROOT" cryptroot -
unset LUKS_PASS LUKS_PASS2

# --- Filesystems ---

echo "Creating filesystems..."
mkfs.fat -F 32 "$PART_BOOT"
mkfs.btrfs -f /dev/mapper/cryptroot

echo "Creating btrfs subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
umount /mnt

echo "Mounting subvolumes..."
mount -o compress=zstd,noatime,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var}
mount -o compress=zstd,noatime,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o compress=zstd,noatime,subvol=@var /dev/mapper/cryptroot /mnt/var
mount "$PART_BOOT" /mnt/boot

# --- Install base system ---

echo
echo "Installing base system..."
PKGS=(base linux linux-lts linux-firmware btrfs-progs networkmanager git curl systemd-zram-generator)
if [[ -n "$UCODE" ]]; then
  PKGS+=("$UCODE")
fi
pacstrap -K /mnt "${PKGS[@]}"

# --- Configure ---

echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "Configuring system..."
arch-chroot /mnt bash -s -- "$HOSTNAME" "$SYS_LANG" "$TIMEZONE" "$USERNAME" "$PART_ROOT" "$UCODE" <<'CHROOT'
set -euo pipefail

HOSTNAME="$1"
SYS_LANG="$2"
TIMEZONE="$3"
USERNAME="$4"
PART_ROOT="$5"
UCODE="$6"

# Timezone & clock
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc --utc

# Locale
sed -i "s/^#${SYS_LANG}/${SYS_LANG}/" /etc/locale.gen
locale-gen
echo "LANG=$SYS_LANG" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Initramfs — add encrypt hook for LUKS
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader — systemd-boot
bootctl install

CRYPT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor  no
EOF

BOOT_OPTS="cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"

{
  echo "title   Arch Linux"
  echo "linux   /vmlinuz-linux"
  [[ -n "$UCODE" ]] && echo "initrd  /${UCODE}.img"
  echo "initrd  /initramfs-linux.img"
  echo "options $BOOT_OPTS"
} > /boot/loader/entries/arch.conf

{
  echo "title   Arch Linux (LTS)"
  echo "linux   /vmlinuz-linux-lts"
  [[ -n "$UCODE" ]] && echo "initrd  /${UCODE}.img"
  echo "initrd  /initramfs-linux-lts.img"
  echo "options $BOOT_OPTS"
} > /boot/loader/entries/arch-lts.conf

# User
useradd -m -G wheel -s /bin/bash "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# zram swap
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF

CHROOT

# Set user password
echo "${USERNAME}:${USER_PASS}" | arch-chroot /mnt chpasswd
unset USER_PASS USER_PASS2

# --- Done ---

echo
echo "=== Installation complete ==="
echo "Reboot, remove the USB, and unlock LUKS at boot."
echo "Then connect to wifi:"
echo "  nmcli device wifi connect YOUR_SSID password YOUR_PASS"
