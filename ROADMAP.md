# Roadmap

Staged so each stage produces a **verifiable** result and fails loudly if the
approach is dead. Do not start a stage before the previous one's exit criteria
are met — that is how the native-port build was debugged (one real error at a
time) and it is the only way to keep this honest.

## Stage 0 — foundation *(current)*

- [x] Repo, architecture, decision recorded (Linux ELF + box64 + GL→Metal).
- [x] `scripts/fetch-box64.sh` clones box64 at a pinned commit.
- [x] `scripts/build-box64-ios.sh` attempts an iOS arm64 cross-compile.
- [x] **Port blockers enumerated from source** → [`PORTING-box64.md`](PORTING-box64.md).

**Exit criteria: met.** The blocker list exists and is evidence-based
(`file:line` into box64). Key result: box64 assumes a **Linux host kernel**
(syscall passthrough, `x64syscall.c:444-450`), so the port is a syscall-layer
**rewrite** plus a **W^X dynarec** change — not a few primitives. Scale is now
known *before* spending Stage-1 effort, which is the point of Stage 0.

## Stage 1 — box64 runs *anything* on iOS

Get box64, built for iOS and packaged as a TrollStore `.tipa` with
`dynamic-codesigning`, to JIT-execute a trivial static x86-64 Linux hello world.

**Exit criteria (go/no-go for the entire project):**
- JIT memory can be allocated and executed on the target device.
  *(Expected to pass — TrollStore's `dynamic-codesigning` grants this. See
  `packaging/entitlements.plist`.)*
- A static x86-64 ELF prints "hello" through box64.

The JIT grant is no longer the risk here (TrollStore solves it). The real risk
is box64's Darwin/iOS port — Mach-O host, Darwin mmap/thread/signal primitives.
That is what Stage 0's build attempt exists to enumerate.

## Stage 2 — dynamic ELF + Linux syscalls

Run a *dynamically linked* x86-64 Linux binary (needs the loader + libc +
syscall forwarding to Darwin). Target: `glxgears` or an SDL2 hello-triangle.

**Exit criteria:** a dynamically linked GL program renders a frame through the
GL→Metal path.

## Stage 3 — GMod dedicated server (headless)

GMod's Linux `srcds` has no graphics. Running it isolates layers 2+3 from layer
4 and proves the engine's CPU/syscall side works under emulation.

**Exit criteria:** `srcds` loads a map and ticks without graphics.

## Stage 4 — GMod client, first frame

Add the graphics layer. Get the main menu to render.

**Exit criteria:** main menu draws and accepts input.

## Stage 5 — playable

Load a map, move around, measure real frame time against the native port.

**Exit criteria:** an honest FPS comparison table vs the native arm64 build.

---

### Reality checkpoints

- Stages 1 and 2 are the true risk. If either can't be met on real hardware,
  the project is done and the native port wins by default.
- Nothing here is testable without macOS + an iOS device with a JIT path.
  CI can attempt the *builds*; only a device proves *execution*.
