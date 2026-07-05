# env-arch

Automated Arch Linux installer with LUKS2 encryption.

Installs a bare-minimum system — just enough to boot, connect to wifi, and clone your env setup repo.

## What it installs

- **Boot**: 1 GiB FAT32 ESP (`/boot`), systemd-boot
- **Root**: LUKS2-encrypted btrfs, rest of disk
  - `@` -> `/`
  - `@home` -> `/home`
  - `@var` -> `/var`
  - Mount options: `compress=zstd,noatime`
- **Swap**: zram (no disk partition)
- **Kernels**: `linux`, `linux-lts`
- **Packages**: `git`, `curl`, `networkmanager`, `intel-ucode` or `amd-ucode` (auto-detected), `btrfs-progs`
- **Services**: NetworkManager, fstrim.timer

## Usage from Arch ISO

Connect to wifi first:

```bash
iwctl --passphrase 'YOUR_PASS' station wlan0 connect YOUR_SSID
```

Quote the passphrase with single quotes to avoid shell interpretation of special characters like `!`.

Then run the installer:

```bash
curl -fsSL https://github.com/hicolour/env-arch/releases/latest/download/env-arch.tar.gz | tar xz
cd env-arch && ./install.sh
```

For a different disk:

```bash
DISK=/dev/nvme1n1 ./install.sh
```

The script checks connectivity, auto-detects CPU microcode (Intel/AMD), asks for hostname, username, LUKS passphrase, and user password, then partitions, encrypts, and installs everything using standard tools (sgdisk, cryptsetup, pacstrap, arch-chroot).

## After install

```bash
nmcli device wifi connect YOUR_SSID password YOUR_PASS
git clone https://github.com/OWNER/your-env-setup
cd your-env-setup && ./install.sh
```

## Releases

```bash
git tag v1.0.0 && git push --tags
```

GitHub Actions packages `install.sh` into `env-arch.tar.gz` and attaches it to the release.

## Security

Passwords are passed via variables and unset immediately after use. Nothing is written to disk.
