# Architecture

## What "emulate the engine" actually means

There is no single "Source emulator" to write. Running stock x86-64 game
binaries on an arm64 iOS device requires four independent layers, each a real
project, stacked on top of each other:

```
  ┌─────────────────────────────────────────────────────────┐
  │  GMod x86-64 game binaries (unmodified ELF)              │  <- the goal
  ├─────────────────────────────────────────────────────────┤
  │  4. Graphics translation   OpenGL  ->  Metal            │
  ├─────────────────────────────────────────────────────────┤
  │  3. Linux userspace shim   ELF loader + libc + syscalls │
  ├─────────────────────────────────────────────────────────┤
  │  2. x86-64 -> arm64 JIT    box64                        │
  ├─────────────────────────────────────────────────────────┤
  │  1. iOS host app           JIT entitlement, W^X, mmap   │
  └─────────────────────────────────────────────────────────┘
```

You do not get to skip any layer. GMod calls `glXSwapBuffers`, `dlopen`,
`mmap`, `futex`, `pthread_create`; the binary is an ELF that must be loaded and
relocated; every instruction is x86-64 that the CPU can't run natively.

## Why *full* emulation, not partial

Decided deliberately — see the conversation that spawned this repo. Short
version:

- Source modules (`engine`, `client`, `server`, `materialsystem`, `vphysics`)
  connect through `CreateInterface`, which hands out **C++ objects with
  vtables**. The factory lookup happens once at load; the **vtable method calls
  happen thousands of times per frame** for the whole session.
- A *partial* scheme (native arm64 for some modules, emulated x86-64 for others)
  must place a **mode-switch thunk** on every one of those cross-module calls:
  save arm64 state, translate the calling convention, enter the JIT, return,
  unwind. That thunk cannot be cached or inlined away.
- Because Source's inter-module boundaries are *hot* (render, trace, physics,
  entity think all cross them per frame), the thunk flood makes partial
  emulation **slower** than keeping everything in one translation domain.

So: emulate everything, cross no live C++ boundary between native and emulated
code. Uniform ~2×-and-worse CPU tax, but zero per-call mode switches.

## The layers in detail

### 1. iOS host app — the JIT problem

box64 is a JIT: it writes arm64 code into memory at runtime and executes it.
iOS forbids `mmap(PROT_EXEC | PROT_WRITE)` for normal apps.

**This project targets TrollStore installation, which solves it.** A `.tipa`
installed via TrollStore is signed with real entitlements, including
`dynamic-codesigning`. That grants persistent JIT: `MAP_JIT` regions plus
`pthread_jit_write_protect_np()` W^X toggling, the same mechanism browser JS
engines use — but permanent and not dependent on a debugger being attached.

This is the difference between "maybe impossible" and "solved":

- **With TrollStore (our target):** `dynamic-codesigning` in the entitlements
  plist → box64's dynarec writes and executes translated arm64 code normally.
  See `packaging/entitlements.plist`.
- Non-TrollStore fallbacks (AltStore JIT-on-launch, the `CS_DEBUGGED`
  debugger-attach trick) exist but are fragile and iOS-version-dependent. We do
  not target them.

Because TrollStore retires the JIT risk, the interpreter-only collapse
(10-40× slower) is off the table for the target device. The remaining Stage-1
risk is purely box64's Darwin/iOS port, not the JIT grant.

### 2. box64 — x86-64 → arm64

Upstream box64 targets arm64 **Linux**. It is not built for Darwin/iOS. Known
gaps to close: Mach-O host packaging instead of ELF host, Darwin `mmap`/thread
primitives, signal handling, and the JIT write path above. box64 already has an
Android arm64 port, which is the closest precedent and the reference to follow.

### 3. Linux userspace shim

The GMod ELF bins are dynamically linked against a Linux libc and call Linux
syscalls. box64 intercepts x86-64 Linux syscalls and can forward many to the
host — but the host here is Darwin, whose syscall ABI and semantics differ
(`futex`, `epoll`, `/proc`, `clone` flags). This shim is the least-charted part
of the stack on iOS.

### 4. Graphics translation

GMod-on-Linux renders with OpenGL. iOS has no OpenGL driver we can rely on
long-term (deprecated) and no Vulkan. The realistic sink is **Metal**, reached
via GL→Metal (ANGLE's Metal backend, or MoltenGL). This is the same GL→Metal
concern the native port also has, so work here can be shared with that tree.

## Honest cost statement

"~2×" is the CPU-only, steady-state, well-behaved-code figure for a good JIT.
Real emulated game frames pay more: graphics translation, syscall forwarding,
translation-cache misses on cold code, and iOS's constrained JIT. Budget for
"noticeably worse than 2×," not "2× and done."
