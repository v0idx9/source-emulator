# source-emulator

Running a **64-bit Source-engine game (Garry's Mod x86-64 branch)** on **iOS
(arm64)** by running the game's **x86-64 Linux build inside a full Linux VM** on
the device, via **UTM/QEMU** (system-mode TCG) — rather than recompiling the
engine from source.

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) for why a VM beats userspace emulation
and where the real risk now lies.

## Distribution: TrollStore

Installed as a `.tipa` via **TrollStore**, which signs with real entitlements —
crucially `dynamic-codesigning` (`packaging/entitlements.plist`). That is what
makes QEMU's TCG take the fast W^X JIT path instead of split-wx mirror mapping
(UTM's `hasJitEntitlements` branch). On a normal sideload iOS JIT is
fragile-to-impossible; on TrollStore it just works.

## Status

**Foundation.** No playable build yet. Architecture settled; the parts that are
buildable without a Mac/device exist:

- `vm/gmod-qemu.args` — the concrete QEMU machine (TCG, virtio-gpu-gl/virgl).
- `scripts/build-guest-image.sh` — builds the x86-64 Linux guest disk (Mesa
  virgl + SteamCMD) on a Linux host. Runnable here; no macOS needed.
- `packaging/entitlements.plist` — TrollStore entitlements, mirrored from UTM.

See [`ROADMAP.md`](ROADMAP.md).

## Why a VM and not box64 (userspace emulation)

box64 was evaluated first and **rejected**: its syscall layer forwards guest
x86-64 **Linux** syscalls straight to the host kernel — fine on Android (Linux),
fatal on iOS (Darwin), where all 364 would need re-implementing
([`PORTING-box64.md`](PORTING-box64.md) has the file:line evidence).

A **full-system VM** removes that blocker entirely — the guest *is* a real Linux
kernel, so it services its own syscalls. UTM already solves the two hard iOS
problems on top of QEMU:

- **JIT** — `dynamic-codesigning` (TrollStore) → QEMU TCG's W^X path.
- **GPU** — guest Mesa **virgl** → `virtio-gpu` → **ANGLE → Metal**. Real 3D
  acceleration, and GMod-on-Linux is OpenGL, which virgl accelerates.

The remaining unknown is **performance** (full-system TCG + virgl for a
real-time game), not viability. Measured in ROADMAP Stage 4-5.

## Why not just recompile? (the native port)

The native arm64 recompile is *one header commit* from a green iOS build and
carries no emulation or virgl overhead — the recommended path for "play it
well." This repo exists to run **stock, unmodified game binaries** instead.
