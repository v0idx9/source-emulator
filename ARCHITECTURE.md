# Architecture

## Decision: full-system VM (UTM/QEMU), not userspace HLE (box64)

Two ways to run x86-64 Linux GMod on arm64 iOS were evaluated:

| | box64 (userspace HLE) | **UTM / QEMU-system (chosen)** |
|---|---|---|
| What runs | just the game process | a whole Linux VM, game inside it |
| Linux syscalls | **must be re-implemented on Darwin** (364 of them — see PORTING-box64.md) | handled by the **guest Linux kernel** inside the VM — nothing to port |
| iOS JIT | you build the W^X path yourself | **already solved by UTM** (`split-wx`/entitlement) |
| CPU cost | lower (HLE) | higher (full-system TCG) |
| GPU | you build GL→Metal yourself | **virtio-gpu + virgl + ANGLE→Metal, already in UTM** |
| Net | one project-killing blocker (syscalls) | no project-killing blocker; risk is *performance* |

box64 was rejected because its syscall layer is a passthrough to a **Linux host
kernel** (`x64syscall.c:444-450`) — on Darwin that becomes a Darling/WSL1-class
rewrite. Full-system emulation sidesteps it completely: the guest *is* Linux, so
Linux syscalls are serviced by the guest kernel, not translated to Darwin.

`PORTING-box64.md` is kept as the record of *why* HLE was rejected.

## The stack (UTM/QEMU path)

```
  ┌─────────────────────────────────────────────────────────┐
  │  GMod (x86-64 Linux build) — unmodified                 │
  ├─────────────────────────────────────────────────────────┤
  │  Guest: real x86-64 Linux kernel + Mesa (virgl driver)  │  <- services its
  ├─────────────────────────────────────────────────────────┤     own syscalls
  │  QEMU system, -accel tcg  (x86-64 translated to arm64)  │
  ├─────────────────────────────────────────────────────────┤
  │  UTM: JIT (split-wx / dynamic-codesigning) + virglrenderer│
  ├─────────────────────────────────────────────────────────┤
  │  iOS host: Metal (via ANGLE), TrollStore entitlements   │
  └─────────────────────────────────────────────────────────┘
```

### JIT — solved by UTM (evidence)

`Configuration/UTMQemuConfiguration+Arguments.swift:553-554`:

```swift
// use mirror mapping when we don't have JIT entitlements
if !UTMCapabilities.current.contains(.hasJitEntitlements) {
    "split-wx=on"
```

With TrollStore's `dynamic-codesigning` entitlement, `hasJitEntitlements` is
true and QEMU's TCG writes/executes translated code directly. Without it, UTM
falls back to a split write/execute mirror mapping. `Services/UTMJailbreak.m`
handles the non-TrollStore `CS_DEBUGGED` detection. Either way, **we do not
write the iOS JIT layer** — UTM already did.

### Why TCG, not HVF (evidence)

`…+Arguments.swift:532-546`: HVF (`-accel hvf`) is only emitted when
`isHypervisorUsed`, i.e. guest architecture matches host. An x86-64 guest on an
arm64 device never matches, so it is forced to `-accel tcg` with a `tb-size`
translation cache. This is full dynamic translation — the source of the CPU
cost.

### Graphics — virgl → ANGLE → Metal (evidence)

`…+Arguments.swift:355-362` selects `qemuRendererBackendAngleMetal`, and `:92`
notes virglrenderer shmem. Path: guest **Mesa virgl** GL driver → `virtio-gpu`
→ host `virglrenderer` → ANGLE → Metal. This is real 3D acceleration, not
llvmpipe software rendering. GMod-on-Linux renders with OpenGL, which is exactly
what the virgl guest driver accelerates.

## The remaining risk is performance, and it is real

This path has **no impossible blocker** — every layer exists and ships in UTM
today. What is unproven is whether a **real-time 3D game** is playable through:

- full-system **x86-64 TCG** (CPU translated, no hardware virt), plus
- **virgl** GL command translation across the VM boundary to ANGLE/Metal.

TCG is heavier than box64's HLE, and virgl adds per-call marshalling. Emulated
*desktop* Linux in UTM is usable; a shooter is a much higher bar. The honest
expectation is "boots and renders, framerate TBD, quite possibly low." That is a
performance question to measure (ROADMAP Stage 4-5), not a viability wall — which
is the crucial difference from the box64 path.

If the framerate proves unplayable, the fallback remains the **native arm64
source port**, which has neither emulation nor virgl overhead.
