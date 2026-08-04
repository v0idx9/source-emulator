# box64 → iOS/Darwin: the real port blockers

Findings from reading **box64 v0.3.2** source directly (not guesswork). Each
item cites `file:line` in upstream box64 so it can be verified. This is the
Stage-1 task list ROADMAP promised.

**Headline:** box64 assumes a **Linux host kernel** end to end. Its Android
target works only because Android *is* Linux. iOS is a Darwin/XNU kernel, so the
port is not "tweak a few primitives" — it is a **rewrite of the syscall layer**
plus a **W^X dynarec change**. Honest scale: large. This document exists so that
scale is known before time is spent, not discovered halfway.

Ordered by how fundamental the blocker is.

---

## 1. Syscall model is passthrough to a Linux kernel *(deepest blocker)*

`src/emu/x64syscall.c:444-450` — the guest's x86-64 **Linux** syscall number is
forwarded straight to the host kernel:

```c
case 0: S_RAX = syscall(sc); break;
case 1: S_RAX = syscall(sc, R_RDI); break;
... up to 6 args
```

364 syscalls are handled this way (`grep -c` over the file). Specific Linux
numbers are hard-coded: `__NR_clone`, `__NR_futex_waitv`, `__NR_getdents64`,
`__NR_inotify_init1`, `__NR_openat` (lines 627, 671, 766, 773, 833, …).

**Why it breaks on iOS:** Darwin's kernel does not implement Linux syscall
numbers or semantics, and arbitrary `syscall()` is not a supported app
interface. Every guest Linux syscall must be **translated** to a Darwin
equivalent or emulated in userspace. Passthrough is impossible.

**Work:** replace the passthrough table with a Linux-syscall-emulation layer.
This is most of a Linux-userspace personality (à la what WSL1 or Darling do).
The hardest individual cases:
- `futex` → no direct Darwin analog; build on `__ulock_wait/wake` or a
  mutex/condvar table.
- `clone` → Darwin has no `clone`; map to `bsdthread_create`/`pthread`.
- `getdents64` → different Darwin `dirent`; translate.
- `inotify` → re-implement over `kqueue`/FSEvents.

## 2. Dynarec allocates RWX; iOS requires W^X + MAP_JIT

`src/custommem.c:830, 889, 895, 906` allocate JIT memory as
`PROT_READ|PROT_WRITE|PROT_EXEC` simultaneously:

```c
p = internal_mmap(NULL, allocsize, PROT_READ|PROT_WRITE|PROT_EXEC,
                  MAP_ANONYMOUS|MAP_PRIVATE, -1, 0);
```

**Why it breaks on iOS:** RWX is rejected even with the TrollStore JIT
entitlement. `dynamic-codesigning` grants a **W^X** model: `MAP_JIT` regions
that are writable **or** executable per-thread, toggled with
`pthread_jit_write_protect_np(false/true)` around every code emission.

**Work:** allocate the dynarec block with `MAP_JIT`; wrap every write into
translated code (the block emit in `src/dynarec/…`, and the SMC/protection
paths at `custommem.c:1370-1588`) with the W^X toggle; `sys_icache_invalidate()`
after emit instead of relying on Linux `__clear_cache` semantics. This is a
contained but pervasive change — every place that writes code must toggle.

## 3. /proc dependence

`/proc/self/maps` and friends are read in `src/custommem.c`,
`src/elfs/elfloader.c`, `src/libtools/signals.c`, `src/tools/my_cpuid.c`,
`src/wrapped/wrappedlibc.c` (13 hits). Used to discover memory layout and back
the guest's own `/proc` reads.

**Why it breaks on iOS:** Darwin has no `/proc`.

**Work:** replace host-side maps discovery with Mach `mach_vm_region` /
`task_info`; synthesize guest-visible `/proc/self/maps` from box64's own memory
bookkeeping.

## 4. Linux-only mmap flags

`MAP_HUGETLB` (`custommem.c:889`), `MAP_32BIT`, `MAP_FIXED_NOREPLACE`,
`MAP_GROWSDOWN` (`src/wrapped/wrappedlibc.c:2982-3036`).

**Why it breaks on iOS:** these flags don't exist on Darwin. `MAP_32BIT`
matters — box64 uses it to keep allocations in the low 4 GB for 32-bit guest
compatibility; Darwin needs a different low-memory reservation strategy.

**Work:** `#ifdef` the Linux flags out; implement a low-address reservation for
the `MAP_32BIT` cases.

## 5. Signal/ucontext layout

`src/libtools/signals.c` manipulates Linux `ucontext_t`/`mcontext_t` `greg`
arrays to read and rewrite guest register state on `SIGSEGV` — essential for
dynarec self-modifying-code handling and fault recovery.

**Why it breaks on iOS:** Darwin arm64 uses `__darwin_arm_thread_state64`
(`_STRUCT_MCONTEXT64`), a different layout. Signal delivery semantics differ too.

**Work:** a Darwin-specific `mcontext` accessor; verify SIGSEGV-driven SMC
detection still works under the MAP_JIT W^X model (faults will differ).

## 6. Build system has no Apple/iOS target

`CMakeLists.txt` knows `M1` (Apple silicon **running Asahi Linux**, still
Linux), `ANDROID`, `TERMUX`, and generic Linux — **no** `APPLE`/`iOS` branch.
Android pulls `android-sysv-semaphore` and ships `libc++_shared.so`
(`CMakeLists.txt:1103, 1213`).

**Work:** a new iOS toolchain path producing a Mach-O static lib/executable,
linking the SDK libc++, no Android artifacts. `scripts/build-box64-ios.sh` is
the stub that will surface the first CMake wall.

---

## Honest verdict

Items 2–6 are each contained and doable. **Item 1 is the project.** Turning
box64's Linux-passthrough syscall layer into a Darwin-hosted Linux-syscall
*emulation* layer is a Darling/WSL1-class effort, independent of and larger than
the graphics and packaging work. It should be prototyped and de-risked (ROADMAP
Stage 1→2) before any engine work begins.

If item 1 proves too large, the fallback is not partial emulation (slower, per
earlier analysis) — it is the **native arm64 source port**, which sidesteps
every blocker on this page because it never emulates anything.
