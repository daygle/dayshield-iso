# dayshield-iso

Deterministic, reproducible hybrid BIOS+UEFI bootable installer ISO for the
**DayShield Firewall OS**.

Takes the output of [dayshield-rootfs](https://github.com/daygle/dayshield-rootfs)
(`rootfs.tar.zst`) and produces a signed, bit-for-bit reproducible `.iso` file.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Repository layout](#repository-layout)
3. [Building the ISO](#building-the-iso)
4. [Testing in QEMU](#testing-in-qemu)
5. [Running the installer](#running-the-installer)
6. [Integration with rootfs builder](#integration-with-rootfs-builder)
7. [Design decisions](#design-decisions)

---

## Requirements

### Build host packages

| Package | Purpose |
|---------|---------|
| `xorriso` | ISO creation (mkisofs-compatible with hybrid MBR+GPT support) |
| `squashfs-tools` | `mksquashfs` — creates the live squashfs image |
| `grub-pc-bin` | GRUB BIOS modules (`i386-pc`) |
| `grub-efi-amd64-bin` | GRUB UEFI modules (`x86_64-efi`) |
| `dosfstools` | `mkfs.fat` — formats the EFI System Partition image |
| `dracut` or `initramfs-tools` | initrd generation |
| `zstd` | zstd decompression for rootfs extraction |
| `parted` | disk partitioning (used by installer) |
| `rsync` | rootfs copy in installer (optional fallback to tar) |

Install on Debian/Ubuntu:

```sh
sudo apt-get install \
    xorriso squashfs-tools grub-pc-bin grub-efi-amd64-bin \
    dosfstools dracut zstd parted rsync
```

---

## Repository layout

```
dayshield-iso/
├── scripts/
│   ├── build-iso.sh          # Main entrypoint
│   ├── extract-rootfs.sh     # Extract rootfs.tar.zst → build/rootfs/
│   ├── build-squashfs.sh     # Build deterministic squashfs image
│   ├── build-kernel.sh       # Locate/extract vmlinuz + initrd
│   ├── build-initrd.sh       # Build installer initrd (dracut/mkinitramfs)
│   ├── build-bootloader.sh   # Build hybrid BIOS+UEFI GRUB images
│   ├── assemble-iso.sh       # Assemble final ISO with xorriso
│   ├── cleanup.sh            # Remove intermediate artefacts
│   └── verify.sh             # Content and boot verification
├── config/
│   ├── grub.cfg              # GRUB boot menu
│   ├── isolinux.cfg          # ISOLINUX/SYSLINUX fallback menu
│   ├── splash.png            # Optional boot splash (place here)
│   └── installer/
│       ├── install.sh              # Top-level installer orchestrator
│       ├── partition.sh            # GPT disk partitioning
│       ├── copy-rootfs.sh          # squashfs → target filesystem copy
│       ├── configure-bootloader.sh # Install GRUB on target disk
│       ├── firstboot.service       # systemd unit for first-boot tasks
│       └── firstboot-run.sh        # First-boot script (SSH keys, machine-id…)
├── Makefile
└── README.md
```

---

## Building the ISO

### Quick start

```sh
# From the dayshield-iso repository root
make iso ROOTFS=../dayshield-rootfs/rootfs.tar.zst

# Custom output path
make iso ROOTFS=/path/to/rootfs.tar.zst OUTPUT=/output/dayshield.iso
```

The built ISO is written to `dayshield.iso` (or the path given via `OUTPUT=`).

### Manual invocation

```sh
bash scripts/build-iso.sh \
    --rootfs ../dayshield-rootfs/rootfs.tar.zst \
    --output dayshield.iso \
    --arch   amd64
```

### Pipeline steps

| Step | Script | Output |
|------|--------|--------|
| 1. Extract rootfs | `extract-rootfs.sh` | `build/rootfs/` |
| 2. Build squashfs | `build-squashfs.sh` | `build/squashfs-rootfs.sqsh` |
| 3. Locate kernel  | `build-kernel.sh`   | `build/kernel/vmlinuz`, `build/kernel/initrd.img` |
| 4. Build initrd   | `build-initrd.sh`   | `build/kernel/initrd.img` (replaced) |
| 5. Build bootloader | `build-bootloader.sh` | `build/bootloader/` |
| 6. Assemble ISO   | `assemble-iso.sh`   | `dayshield.iso` |
| 7. Cleanup        | `cleanup.sh`        | removes `build/` |

### Reproducibility

The build pipeline enforces deterministic output:

- All file timestamps are normalised to **epoch 0** (`1970-01-01T00:00:00Z`).
- `mksquashfs` is called with `-mkfs-time 0`, `-no-fragments`, `-all-root`.
- `xorriso` is called with `-set_all_file_dates 0`.
- No network calls are made during the build.
- IPv6 is disabled (`ipv6.disable=1`) in all kernel command lines.

---

## Testing in QEMU

### BIOS boot

```sh
qemu-system-x86_64 \
    -m 1G \
    -cdrom dayshield.iso \
    -boot d \
    -nographic
```

### UEFI boot

```sh
# Install OVMF: sudo apt-get install ovmf
qemu-system-x86_64 \
    -m 1G \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
    -cdrom dayshield.iso \
    -boot d \
    -nographic
```

### Automated verification

```sh
# Content-only verification (no QEMU required)
make verify ISO=dayshield.iso

# Content + QEMU BIOS boot
make verify-qemu ISO=dayshield.iso

# Content + QEMU BIOS + UEFI boot
make verify-qemu ISO=dayshield.iso OVMF=/usr/share/OVMF/OVMF_CODE.fd
```

---

## Running the installer

Boot the ISO in a VM or on bare metal. The live environment will auto-start
or you can invoke the installer manually:

```sh
# Auto-detect target disk
sudo /usr/lib/dayshield-installer/install.sh

# Specify target disk explicitly
sudo DAYSHIELD_TARGET_DISK=/dev/sda /usr/lib/dayshield-installer/install.sh

# Unattended (no confirmation prompt)
sudo DAYSHIELD_TARGET_DISK=/dev/sda DAYSHIELD_UNATTENDED=1 \
    /usr/lib/dayshield-installer/install.sh
```

The installer:

1. Partitions the target disk (GPT: 512 MiB EFI + rest root)
2. Formats EFI as FAT32, root as ext4
3. Copies the squashfs live image to the target root
4. Installs GRUB (BIOS + UEFI)
5. Enables `firstboot.service`

On first boot:

- SSH host keys are regenerated
- `machine-id` is regenerated
- ACME/TLS keys are regenerated (if `dayshield-acme` is installed)
- Stale DHCP leases are removed
- `dayshield-core` service is started

---

## Integration with rootfs builder

```sh
# In dayshield-rootfs repository
make rootfs          # produces rootfs.tar.zst

# In dayshield-iso repository
make iso ROOTFS=../dayshield-rootfs/rootfs.tar.zst
```

Or as a single pipeline:

```sh
( cd ../dayshield-rootfs && make rootfs ) && \
make iso ROOTFS=../dayshield-rootfs/rootfs.tar.zst
```

---

## Design decisions

| Decision | Rationale |
|----------|-----------|
| GRUB over systemd-boot | GRUB provides both BIOS and UEFI support from a single binary set; systemd-boot is UEFI-only |
| zstd compression for squashfs | Best compression ratio vs. decompression speed for live boots |
| Epoch-0 timestamps | Required for reproducible builds; matches Debian's `SOURCE_DATE_EPOCH` convention |
| No IPv6 | `ipv6.disable=1` kernel parameter + dracut `omit_dracutmodules+=" ipv6 "` |
| GPT partitioning | Required for UEFI; also supported by modern BIOS-boot GRUB |
| ext4 root filesystem | Best compatibility with the Debian-based rootfs |
