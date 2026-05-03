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
6. [Integration with other repos](#integration-with-other-repos)
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
    dosfstools dracut zstd parted rsync util-linux
```

> **Note:** `live-boot`, `live-config`, and `squashfs-tools` are included
> inside the rootfs itself (via `dayshield-rootfs/config/packages.txt`) so
> the live initrd can mount the squashfs root.  They do not need to be
> installed on the build host.

---

## Repository layout

```
dayshield-iso/
├── scripts/
│   ├── build-iso.sh              # Main entrypoint
│   ├── extract-rootfs.sh         # Extract rootfs.tar.zst → build/rootfs/
│   ├── inject-installer-ui.sh    # Inject web installer UI into live rootfs
│   ├── build-squashfs.sh         # Build deterministic squashfs image
│   ├── build-kernel.sh           # Locate/extract vmlinuz + initrd
│   ├── build-initrd.sh           # Build installer initrd (dracut/mkinitramfs)
│   ├── build-bootloader.sh       # Build hybrid BIOS+UEFI GRUB images
│   ├── assemble-iso.sh           # Assemble final ISO with xorriso
│   ├── cleanup.sh                # Remove intermediate artefacts
│   └── verify.sh                 # Content and boot verification
├── config/
│   ├── grub.cfg                  # GRUB boot menu
│   ├── isolinux.cfg              # ISOLINUX/SYSLINUX fallback menu
│   ├── splash.png                # Optional boot splash (place here)
│   └── installer/
│       ├── install.sh              # CLI installer orchestrator (fallback)
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
make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui

# Custom output path
make iso \
    ROOTFS=/path/to/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui \
    OUTPUT=/output/dayshield.iso
```

The built ISO is written to `dayshield.iso` (or the path given via `OUTPUT=`).

`INSTALLER_UI` is optional but strongly recommended — without it the web-based
installer UI will not be present in the live environment.

### Manual invocation

```sh
bash scripts/build-iso.sh \
    --rootfs       ../dayshield-rootfs/rootfs.tar.zst \
    --installer-ui ../dayshield-installer-ui/installer-ui \
    --output       dayshield.iso \
    --arch         amd64
```

### Pipeline steps

| Step | Script | Output |
|------|--------|--------|
| 1. Extract rootfs       | `extract-rootfs.sh`       | `build/rootfs/` |
| 2. Inject installer UI  | `inject-installer-ui.sh`  | `build/rootfs/installer-ui/`, service units enabled |
| 3. Build squashfs       | `build-squashfs.sh`       | `build/squashfs-rootfs.sqsh` |
| 4. Locate kernel        | `build-kernel.sh`         | `build/kernel/vmlinuz`, `build/kernel/initrd.img` |
| 5. Build initrd         | `build-initrd.sh`         | `build/kernel/initrd.img` (replaced) |
| 6. Build bootloader     | `build-bootloader.sh`     | `build/bootloader/` |
| 7. Assemble ISO         | `assemble-iso.sh`         | `dayshield.iso` |
| 8. Cleanup              | `cleanup.sh`              | removes `build/` |

> Step 2 is skipped when `--installer-ui` is not passed.

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

Boot the ISO in a VM or on bare metal.  When the `installer` kernel parameter
is present (the default in all boot menu entries), the live environment
automatically starts the **web-based installer UI** on `tty1`:

- `installer-ui-web.service` — serves the installer on `http://127.0.0.1:8080`
- `installer-ui.service` — opens a browser on `tty1` pointing at the above URL

If a graphical browser (`surf`, `midori`) is unavailable, `w3m` is used as a
text-browser fallback.  The URL is always `http://127.0.0.1:8080/`.

### Web UI installation flow

1. **Welcome** — brief overview
2. **Disk selection** — lists available disks via `/api/detect-disks.sh`
3. **Partition** — creates GPT layout: 512 MiB EFI + remaining root
4. **Format** — FAT32 EFI + ext4 root
5. **Install rootfs** — extracts `rootfs.tar.zst` from the ISO to the target
6. **Install bootloader** — installs GRUB (BIOS + UEFI) on the target disk
7. **Configure** — hostname, root password, primary network interface
8. **Finalize** — unmounts, syncs, removes installer artefacts
9. **Reboot**

### CLI fallback (no web UI)

If the ISO was built without `--installer-ui`, shell scripts are still
available under `/usr/lib/dayshield-installer/`:

```sh
# Auto-detect target disk
sudo /usr/lib/dayshield-installer/install.sh

# Specify target disk explicitly
sudo DAYSHIELD_TARGET_DISK=/dev/sda /usr/lib/dayshield-installer/install.sh
```

### First boot (after install)

- SSH host keys are regenerated
- `machine-id` is regenerated
- ACME/TLS keys are regenerated (if `dayshield-acme` is installed)
- Stale DHCP leases are removed
- `dayshield-core` service is started

---

## Integration with other repos

### Building from scratch (all three repos)

```sh
# 1. Build the root filesystem
( cd ../dayshield-rootfs && make rootfs )

# 2. Build the ISO (includes installer UI)
make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

### Alpine.js bundle (required for installer UI)

The installer UI uses Alpine.js for reactivity. Because the ISO is fully
offline, the bundle must be present at
`installer-ui/alpine.min.js` **before** the ISO build:

```sh
curl -Lo ../dayshield-installer-ui/installer-ui/alpine.min.js \
  "https://cdn.jsdelivr.net/npm/alpinejs@3/dist/cdn.min.js"
```

### Compiled Tailwind CSS (optional)

The `styles.css` in the installer UI repo contains Tailwind source directives.
For production, compile it first:

```sh
cd ../dayshield-installer-ui/installer-ui
npm install -D tailwindcss
npx tailwindcss -i styles.css -o dist/styles.css \
    --content "index.html,app.js" --minify
# Then update the <link> in index.html to reference dist/styles.css
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
