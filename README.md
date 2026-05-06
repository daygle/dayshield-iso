# DayShield ISO

Deterministic, reproducible hybrid BIOS+UEFI bootable installer ISO for the
**DayShield Firewall OS**.

Takes the output of [dayshield-rootfs](https://github.com/daygle/dayshield-rootfs)
(`rootfs.tar.zst`) and produces a signed, bit-for-bit reproducible `.iso` file.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Repository layout](#repository-layout)
3. [End-to-end build guide](#end-to-end-build-guide)
4. [Building the ISO](#building-the-iso)
5. [Testing in QEMU](#testing-in-qemu)
6. [Running the installer](#running-the-installer)
7. [Integration with other repos](#integration-with-other-repos)
8. [Design decisions](#design-decisions)

---

## Requirements

Build host OS: **Debian 13** (or Ubuntu equivalent).

```sh
apt-get install -y \
    xorriso squashfs-tools grub-pc-bin grub-efi-amd64-bin \
    dosfstools dracut zstd parted rsync util-linux \
    mmdebstrap systemd-container \
    nodejs npm \
    shellcheck
```

**Rust** (for building `dayshield-core`) - install via rustup, not apt:

```sh
curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal --default-toolchain 1.88.0
source "$HOME/.cargo/env"
```

**Node.js / npm** (for building `dayshield-ui` if you want the installed-system UI) - install via the distro package or NodeSource for Node 18+.

See the [Build host packages](#build-host-packages) table for full details.

Optional development tool:

```sh
shellcheck
```

Run linting with:

```sh
make lint
```

---

## End-to-end build guide

This section walks through building a fully functional DayShield installer ISO
from scratch on a Debian 13 build host.  Follow these phases in order.

---

### Phase 1 - Prepare the build host

```sh
# Install all required build tools
apt-get update
apt-get install -y git curl gcc make build-essential mmdebstrap zstd systemd-container xorriso squashfs-tools grub-pc-bin grub-efi-amd64-bin dosfstools dracut dracut-live util-linux parted rsync qemu-system-x86 ovmf nodejs npm

# Install Rust via rustup (do NOT install rustc/cargo/rustup from apt)
curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal --default-toolchain 1.88.0
source "$HOME/.cargo/env"

# Install Node if you need to build the management UI
# Node 18+ is required for `dayshield-ui` build output.
```

---

### Phase 2 - Clone all repos

```sh
cd ~
git clone https://github.com/daygle/dayshield-rootfs
git clone https://github.com/daygle/dayshield-iso
git clone https://github.com/daygle/dayshield-installer-ui
git clone https://github.com/daygle/dayshield-ui
git clone https://github.com/daygle/dayshield-core
```

If you want the installed system to serve the management UI, build `dayshield-ui`
and provide its `dist` output to the rootfs builder.

---

### Phase 3 - Build the dayshield-core binary

The rootfs builder copies the compiled binary into the rootfs.  Without it a
non-functional placeholder is installed and the `dayshield` service will fail
at runtime.

If you installed Rust with rustup in Phase 1, ensure your shell has Cargo on
PATH before building:

```sh
source "$HOME/.cargo/env"
rustc --version
```

```sh
cd ~/dayshield-core

# Build release binary
cargo build --release

# Copy into dayshield-rootfs so the rootfs builder can find it
cp target/release/dayshield-core ~/dayshield-rootfs/dayshield-core
```

---

### Phase 5 - Build the root filesystem

```sh
cd ~/dayshield-rootfs
make rootfs
```

If you want the installed system to serve the Management UI, first build the
UI in the `dayshield-ui` repository and pass its output directory into the
rootfs builder:

```sh
cd ~/dayshield-ui
npm install
npm run build

cd ~/dayshield-rootfs
make rootfs UI_DIR=../dayshield-ui/dist
```

This copies the built UI into `/usr/local/share/dayshield-ui` inside the
rootfs, which is the path expected by `dayshield-core`.

This runs mmdebstrap, chroot-setup, installs dayshield-core, enables all
services, hardens IPv4, and produces:

```
~/dayshield-rootfs/rootfs.tar.zst
```

> **Tip:** the binary must be at `~/dayshield-rootfs/dayshield-core` (Phase 3)
> before this step, or a placeholder is used instead.

#### Verify the rootfs (recommended)

```sh
mkdir -p /tmp/ds-verify
tar -I zstd -xf ~/dayshield-rootfs/rootfs.tar.zst -C /tmp/ds-verify
make -C ~/dayshield-rootfs verify ROOTFS_DIR=/tmp/ds-verify
rm -rf /tmp/ds-verify
```

All checks should exit `[PASS]`.  The script validates:
- Required directories present
- All systemd service units installed and enabled
- `dayshield-core` binary installed and executable
- IPv6 disabled (sysctl, module blacklist, `/etc/hosts`, nftables, unbound)
- nftables, unbound, suricata, and crowdsec configs present

---

### Phase 6 - Build the ISO

```sh
cd ~/dayshield-iso

make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

This build now also writes checksum files next to the ISO:

```sh
dayshield.iso.sha256
dayshield.iso.md5
```

The `INSTALLER_UI` path is for the live installer UI on the ISO.
If you also want the installed system to serve the management UI, build
`dayshield-ui` separately and include it in the rootfs build via
`UI_DIR=../dayshield-ui/dist`.

This runs the full pipeline (extract -> inject installer UI -> squashfs ->
kernel -> initrd -> bootloader -> assemble) and produces:

```
~/dayshield-iso/dayshield.iso
```

#### Verify the ISO (optional)

```sh
make verify ISO=dayshield.iso
```

> **Note:** `verify.sh` currently expects installer assets under
> `/installer-ui/`. Build with `INSTALLER_UI=...` when you intend to run
> `make verify`.

---

### Iterative rebuilds (no snapshot revert needed)

You do not need to revert your build VM to a snapshot between ISO builds.
The build is self-cleaning - just run `make clean` before rebuilding.

**Changed only installer UI files** (scripts, HTML, JS - not `packages.txt`):

```sh
cd ~/dayshield-iso
make clean
make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

`make clean` removes the intermediate `build/` directory only.
The existing `rootfs.tar.zst` is reused as-is - no rootfs rebuild needed.

**Changed rootfs files** (`packages.txt`, service units, scripts):

```sh
cd ~/dayshield-rootfs
make clean && make rootfs

cd ~/dayshield-iso
make clean
make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

**Changed `dayshield-core` source:**

```sh
cd ~/dayshield-core
cargo build --release
cp target/release/dayshield-core ~/dayshield-rootfs/dayshield-core

cd ~/dayshield-rootfs
make clean && make rootfs

cd ~/dayshield-iso
make clean
make iso \
    ROOTFS=../dayshield-rootfs/rootfs.tar.zst \
    INSTALLER_UI=../dayshield-installer-ui/installer-ui
```

> `make distclean` (in dayshield-iso) also removes the final `dayshield.iso`
> in addition to `build/`.  Use it only when you want a fully clean slate.

---

### Phase 7 - Boot the ISO in QEMU

```sh
# BIOS mode
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -accel tcg,thread=multi \
  -cpu max \
  -cdrom dayshield.iso \
  -boot d \
  -nographic

# UEFI mode (OVMF path may vary)
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -accel tcg,thread=multi \
  -cpu max \
  -bios /usr/share/ovmf/OVMF.fd \
  -cdrom dayshield.iso \
  -boot d \
  -nographic
```

Expected boot sequence: GRUB menu -> kernel messages -> systemd -> installer
launched on tty1.

> **Live session login** - username `root`, password `dayshield`.  This
> default is set only for the live/installer environment and is not carried
> forward to the installed system.  The installer's configure step sets the
> real root password before first boot.

> **No boot splash** - Plymouth is not installed.  Plain kernel log is
> intentional.  If you see a panic, check that the ISO label is `DAYSHIELD`
> (`isoinfo -d -i dayshield.iso | grep 'Volume id'`).

---

### Phase 8 - Run the installer

The installer web UI starts automatically.  It is bound to
`0.0.0.0:8443` and is accessible from tty1 (if a supported browser is
available) or from another machine on the same network.

Installation steps:

1. **Select disk** - choose target installation disk
2. **Partition** - creates GPT layout: 1 MiB bios_grub + 512 MiB EFI + remaining root
3. **Format** - FAT32 EFI, ext4 root
4. **Install rootfs** - extracts the rootfs archive from the ISO to the target
5. **Install bootloader** - GRUB BIOS + UEFI on the target disk
6. **Configure** - hostname, root password, primary network interface
7. **Finalize** - unmounts, syncs
8. **Reboot**

> The installer UI is only active when the system is booted from the ISO
> (`installer` kernel parameter).  Both installer services carry
> `ConditionKernelCommandLine=installer` and are silently skipped on the
> installed system.

---

### Phase 9 - First boot validation

After installation and reboot:

```sh
# Check core services
systemctl status dayshield.service
systemctl status unbound
systemctl status nftables
systemctl status suricata
systemctl status crowdsec
systemctl status ssh
```

> **Port note:** port `8443` is the installer UI (live ISO only).

---

### Build host packages

| Package | Purpose |
|---------|---------|
| `xorriso` | ISO creation (mkisofs-compatible with hybrid MBR+GPT support) |
| `squashfs-tools` | `mksquashfs` - creates the live squashfs image |
| `grub-pc-bin` | GRUB BIOS modules (`i386-pc`) |
| `grub-efi-amd64-bin` | GRUB UEFI modules (`x86_64-efi`) |
| `dosfstools` | `mkfs.fat` - formats the EFI System Partition image |
| `dracut` or `initramfs-tools` | initrd generation |
| `zstd` | zstd decompression for rootfs extraction |
| `parted` | disk partitioning (used by installer) |
| `rsync` | rootfs copy in installer (optional fallback to tar) |

Install on Debian/Ubuntu:

```sh
apt-get install \
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
|-- scripts/
|   |-- build-iso.sh              # Main entrypoint
|   |-- extract-rootfs.sh         # Extract rootfs.tar.zst -> build/rootfs/
|   |-- inject-installer-ui.sh    # Inject web installer UI into live rootfs
|   |-- ensure-live-boot.sh       # Ensure live-boot/live-config are present in live rootfs
|   |-- build-squashfs.sh         # Build deterministic squashfs image
|   |-- build-kernel.sh           # Locate/extract vmlinuz + initrd
|   |-- build-initrd.sh           # Build installer initrd (dracut/mkinitramfs)
|   |-- build-bootloader.sh       # Build hybrid BIOS+UEFI GRUB images
|   |-- assemble-iso.sh           # Assemble final ISO with xorriso
|   |-- cleanup.sh                # Remove intermediate artifacts
|   `-- verify.sh                 # Content and boot verification
|-- config/
|   |-- grub.cfg                  # GRUB boot menu
|   |-- isolinux.cfg              # ISOLINUX/SYSLINUX fallback menu
|   `-- installer/
|       |-- install.sh              # CLI installer orchestrator (fallback)
|       |-- partition.sh            # GPT disk partitioning
|       |-- copy-rootfs.sh          # squashfs -> target filesystem copy
|       |-- configure-bootloader.sh # Install GRUB on target disk
|       |-- firstboot.service       # systemd unit for first-boot tasks
|       `-- firstboot-run.sh        # First-boot script (SSH keys, machine-id...)
|-- Makefile
`-- README.md
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

`INSTALLER_UI` is required.

When `INSTALLER_UI` is set, these files are required and validated before the
pipeline starts: `index.html`, `styles.css`, `app.js`, `alpine.min.js`,
`tailwind.min.js`, `httpd.conf`, `systemd/installer-ui.service`, and
`systemd/installer-ui-web.service`.

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
| 3. Ensure live-boot     | `ensure-live-boot.sh`     | `live-boot`/`live-config` installed into `build/rootfs/` if absent |
| 4. Build squashfs       | `build-squashfs.sh`       | `build/squashfs-rootfs.sqsh` |
| 5. Locate kernel        | `build-kernel.sh`         | `build/kernel/vmlinuz`, `build/kernel/initrd.img` |
| 6. Build initrd         | `build-initrd.sh`         | `build/kernel/initrd.img` (replaced) |
| 7. Build bootloader     | `build-bootloader.sh`     | `build/bootloader/` |
| 8. Assemble ISO         | `assemble-iso.sh`         | `dayshield.iso` |
| 9. Cleanup              | `cleanup.sh`              | removes `build/` |

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
  -m 2048 -smp 2 \
  -accel tcg,thread=multi \
  -cpu max \
  -cdrom dayshield.iso \
  -boot d \
  -nographic
```

### UEFI boot

```sh
# Install OVMF: apt-get install ovmf
qemu-system-x86_64 \
  -m 2048 -smp 2 \
  -accel tcg,thread=multi \
  -cpu max \
  -bios /usr/share/ovmf/OVMF.fd \
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

> `verify.sh` expects installer assets under `/installer-ui/`, so build with
> `INSTALLER_UI=...` before running these checks.

---

## Running the installer

Boot the ISO in a VM or on bare metal.  When the `installer` kernel parameter
is present (the default in all boot menu entries), the live environment
automatically starts the **web-based installer UI**:

- `installer-ui-web.service` - serves the installer on `http://0.0.0.0:8443`
  (auto-enabled in `multi-user.target`)
- `installer-ui.service` - opens a browser on `tty1` pointing at the above URL
  (not auto-enabled by default, to avoid VM consoles appearing unresponsive
  when tty ownership is transferred)

Browser launch order if `installer-ui.service` is manually started on tty1:
`epiphany-browser`, `firefox`, `chromium`, `surf`, then `midori`. If none are
installed, the service prints instructions to open the installer from another
machine at `http://<live-ip>:8443/`.

### Web UI installation flow

1. **Welcome** - brief overview
2. **Disk selection** - lists available disks via `/api/detect-disks.sh`
3. **Partition** - creates GPT layout: 1 MiB bios_grub + 512 MiB EFI + remaining root
4. **Format** - FAT32 EFI + ext4 root
5. **Install rootfs** - extracts `rootfs.tar.zst` from the ISO to the target
6. **Install bootloader** - installs GRUB (BIOS + UEFI) on the target disk
7. **Configure** - hostname, root password, primary network interface
8. **Finalize** - unmounts, syncs, removes installer artefacts
9. **Reboot**

### CLI fallback (manual install path)

If the web UI cannot be used, shell installer scripts are available under
`/usr/lib/dayshield-installer/`:

```sh
# Auto-detect target disk
/usr/lib/dayshield-installer/install.sh

# Specify target disk explicitly
DAYSHIELD_TARGET_DISK=/dev/sda /usr/lib/dayshield-installer/install.sh
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

The installer UI repo includes the required offline Alpine and Tailwind
runtime bundles at `installer-ui/alpine.min.js` and
`installer-ui/tailwind.min.js`.

If you want to refresh them manually, run:

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

