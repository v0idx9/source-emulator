#!/usr/bin/env bash
# Build the x86-64 Linux guest disk image that runs inside UTM/QEMU on iOS.
#
# Runs on a LINUX x86-64 host (or any host with qemu-user + debootstrap, or
# Docker). Produces gmod-guest.qcow2: a minimal Debian with Mesa/virgl and
# SteamCMD ready to install Garry's Mod.
#
# The image is built for the *guest*, so it is genuinely native x86-64 work that
# does NOT need macOS or a device. This is the part of the emulator stack that
# is fully buildable here.
#
# GMod itself is NOT downloaded: it needs a Steam account that owns it. The image
# ships SteamCMD and a first-boot unit that installs GMod dedicated when Steam
# creds are provided via the 9p host share. Never commit game files (see
# .gitignore).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/vm/gmod-guest.qcow2"
SIZE="${GUEST_SIZE:-20G}"
SUITE="${GUEST_SUITE:-bookworm}"
WORK="$(mktemp -d)"
MNT=""; LOOP=""
# Unmount the chroot bind-mounts (and loop dev) before wiping WORK, so a failure
# mid-build doesn't leave /proc etc. mounted and make `rm -rf` choke on them.
cleanup() {
	for d in sys proc dev/pts dev; do
		mountpoint -q "${MNT}/$d" 2>/dev/null && sudo umount "${MNT}/$d" 2>/dev/null || true
	done
	[ -n "${MNT}" ] && mountpoint -q "${MNT}" 2>/dev/null && sudo umount "${MNT}" 2>/dev/null || true
	[ -n "${LOOP}" ] && sudo losetup -d "${LOOP}" 2>/dev/null || true
	sudo rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need qemu-img
need debootstrap   # or swap in mmdebstrap; both work

echo "==> base rootfs (${SUITE}, x86-64)"
# linux-image-amd64 gives a bootable kernel+initrd; without it QEMU has nothing
# to boot. mesa virgl driver is libgl1-mesa-dri (provides virtio_gpu/virgl DRI).
sudo debootstrap --arch=amd64 --variant=minbase \
	--include=linux-image-amd64,systemd-sysv,ca-certificates,curl,libgl1-mesa-dri,mesa-utils,libc6-i386,lib32gcc-s1,xserver-xorg-core,xinit,openbox,grub-pc-bin,grub-common,grub2-common \
	"${SUITE}" "${WORK}/rootfs" http://deb.debian.org/debian

# Root password + serial console so the image is loginable and CI can watch boot.
echo "root:root" | sudo chroot "${WORK}/rootfs" chpasswd
sudo ln -sf /lib/systemd/system/serial-getty@.service \
	"${WORK}/rootfs/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true

# Deterministic boot marker for automated boot tests (CI). Prints on the serial
# console once multi-user is up. Harmless on device.
sudo tee "${WORK}/rootfs/etc/systemd/system/boot-marker.service" >/dev/null <<'UNIT'
[Unit]
Description=Print a boot-OK marker to the console
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo GUEST_BOOT_OK > /dev/ttyS0'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
sudo chroot "${WORK}/rootfs" systemctl enable boot-marker.service

echo "==> guest provisioning (virgl check + steamcmd + gmod first-boot unit)"
sudo tee "${WORK}/rootfs/usr/local/sbin/provision.sh" >/dev/null <<'GUEST'
#!/usr/bin/env bash
set -euo pipefail
# SteamCMD (32-bit runtime already pulled in via lib32gcc-s1)
install -d /opt/steamcmd
curl -sL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
	| tar -xz -C /opt/steamcmd
# GMod install is deferred to first boot when creds arrive on the 9p share.
cat >/etc/systemd/system/gmod-install.service <<'UNIT'
[Unit]
Description=Install Garry's Mod via SteamCMD from host share creds
ConditionPathExists=/mnt/hostshare/steam.creds
After=network-online.target
[Service]
Type=oneshot
ExecStartPre=/bin/mkdir -p /mnt/hostshare
ExecStartPre=/bin/mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/hostshare
ExecStart=/bin/bash -c '. /mnt/hostshare/steam.creds; \
	/opt/steamcmd/steamcmd.sh +login "$STEAM_USER" "$STEAM_PASS" \
	+force_install_dir /opt/gmod +app_update 4020 validate +quit'
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable gmod-install.service
GUEST
sudo chmod +x "${WORK}/rootfs/usr/local/sbin/provision.sh"
sudo chroot "${WORK}/rootfs" /usr/local/sbin/provision.sh

echo "==> extract kernel + initrd (kept as a fallback -kernel boot path)"
sudo cp "${WORK}"/rootfs/boot/vmlinuz-* "${ROOT}/vm/vmlinuz"
sudo cp "${WORK}"/rootfs/boot/initrd.img-* "${ROOT}/vm/initrd.img"
sudo chown "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "${ROOT}/vm/vmlinuz" "${ROOT}/vm/initrd.img"

echo "==> build a SELF-BOOTING partitioned disk (GRUB + baked-in kernel cmdline)"
# UTM's "Additional Arguments" field splits every entry on whitespace, so a
# multi-word -append can't be passed through it. The fix: make the disk boot
# itself. We install BIOS GRUB into the MBR and bake the kernel command line
# (root=, rw, console=) into GRUB's config. On device you then boot the disk
# with NO -kernel/-initrd/-append at all - nothing for UTM to mangle.
RAW="${WORK}/guest.raw"
truncate -s "${SIZE}" "${RAW}"
# MBR (msdos) table, one bootable ext4 partition starting at 1MiB (leaves the
# post-MBR gap GRUB needs to embed core.img).
parted -s "${RAW}" mklabel msdos
parted -s "${RAW}" mkpart primary ext4 1MiB 100%
parted -s "${RAW}" set 1 boot on

LOOP="$(sudo losetup --show -fP "${RAW}")"    # -P exposes ${LOOP}p1
sudo mkfs.ext4 -F "${LOOP}p1"
MNT="${WORK}/mnt"
mkdir -p "${MNT}"
sudo mount "${LOOP}p1" "${MNT}"
sudo cp -a "${WORK}/rootfs/." "${MNT}/"

# fstab by UUID so systemd mounts / read-write and doesn't drop to emergency.
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
echo "UUID=${ROOT_UUID} / ext4 errors=remount-ro 0 1" | sudo tee "${MNT}/etc/fstab" >/dev/null

# Bind host /dev,/proc,/sys so grub-install/update-grub work inside the chroot.
for d in dev dev/pts proc sys; do sudo mount --bind "/$d" "${MNT}/$d"; done
# Bake the whole kernel command line here (this is the part UTM used to split).
# Two consoles: tty0 for the on-device graphical display, ttyS0 for CI's serial
# boot watcher. GRUB itself also talks to both so it works headless in CI.
sudo tee "${MNT}/etc/default/grub" >/dev/null <<GRUBCFG
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX="root=UUID=${ROOT_UUID} rw console=tty0 console=ttyS0"
GRUB_TERMINAL="console serial"
GRUB_DISABLE_OS_PROBER=true
GRUBCFG
sudo chroot "${MNT}" grub-install --target=i386-pc --boot-directory=/boot "${LOOP}"
sudo chroot "${MNT}" update-grub

for d in sys proc dev/pts dev; do sudo umount "${MNT}/$d"; done
sudo umount "${MNT}"
sudo losetup -d "${LOOP}"

qemu-img convert -f raw -O qcow2 "${RAW}" "${OUT}"
# Built under sudo, so the image is root-owned; hand it back to the invoking user
# (SUDO_UID set when run via sudo) so qemu/UTM/CI can open it without root.
sudo chown "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "${OUT}"

echo "==> ${OUT} ready ($(du -h "${OUT}" | cut -f1)) - SELF-BOOTING (no -kernel needed)"
echo "    In UTM: attach ONLY this disk (VirtIO). Delete kernel, initrd, and every"
echo "    Additional Argument. Just press Play."
echo "    Boot (desktop, with GPU):"
echo "      qemu-system-x86_64 -accel tcg -m 4096 \\"
echo "        -drive if=virtio,file=${OUT##*/},format=qcow2 -device virtio-gpu-gl-pci"
echo "    Inside the guest, verify GPU accel with:  glxinfo | grep -i renderer"
echo "    Expect 'virgl'; 'llvmpipe' means software rendering (unplayable)."
