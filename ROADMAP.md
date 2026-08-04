# Roadmap

Full-system VM path (UTM/QEMU). Staged so each stage produces a **verifiable**
result and the performance question is answered as early as possible.

## Stage 0 — architecture *(done)*

- [x] Evaluated box64 (userspace HLE); rejected on the Darwin syscall rewrite
      ([`PORTING-box64.md`](PORTING-box64.md), evidence-based).
- [x] Chose full-system UTM/QEMU; confirmed from UTM source that it (a) forces
      TCG for x86-64-on-arm64, (b) already solves iOS JIT via
      `dynamic-codesigning`/split-wx, (c) exposes virgl→ANGLE→Metal GPU.
- [x] TrollStore entitlements mirrored from UTM.

## Stage 1 — guest image *(buildable here, no Mac needed)*

- [ ] `scripts/build-guest-image.sh` produces `gmod-guest.qcow2` (x86-64 Debian
      + Mesa virgl + SteamCMD).
- [ ] Boot it under **desktop qemu-system-x86_64 with `-device virtio-gpu-gl`**
      on a Linux box and confirm `glxinfo` reports the **virgl** renderer, not
      llvmpipe. This validates the GPU path *before* touching iOS.

**Exit criteria:** guest boots on desktop QEMU and reports hardware (virgl) GL.

## Stage 2 — GMod runs in the guest (desktop)

- [ ] Provide Steam creds via the 9p share; `gmod-install.service` installs GMod.
- [ ] Launch GMod inside the desktop-QEMU guest; measure FPS on a real map.

**Exit criteria:** an FPS number for GMod under x86-64 TCG + virgl on desktop.
This is the earliest honest read on whether the whole approach is playable — and
it needs no Apple hardware.

## Stage 3 — UTM on device

- [ ] Build/obtain UTM as a TrollStore `.tipa` with our entitlements.
- [ ] Import the `.utm` bundle wrapping `vm/gmod-qemu.args` + the guest image.

**Exit criteria:** the same guest boots to a Linux desktop on the device.

## Stage 4 — GMod on device, first frame

**Exit criteria:** GMod main menu renders on the device.

## Stage 5 — playable + honest comparison

**Exit criteria:** FPS table on device vs the native arm64 port. If unplayable,
the native port is the answer and this repo documents why.

---

### Why Stage 2 is the pivotal checkpoint

The one real risk is performance, and it can be measured on a Linux desktop
(same TCG + virgl stack, minus iOS packaging) long before any device work. If
GMod is unplayable there, it will not be faster on an iPhone. Do not proceed to
Stage 3 until Stage 2 gives a number worth chasing.
