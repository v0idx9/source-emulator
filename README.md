# source-emulator

Running a **64-bit Source-engine game (Garry's Mod x86-64 branch)** on **iOS
(arm64)** by *emulating* the game's own binaries rather than recompiling the
engine from source.

This is the alternative to the native arm64 source port. It trades a large
one-time port for a large one-time **emulation-stack integration**. Read
[`ARCHITECTURE.md`](ARCHITECTURE.md) before writing any code — the reason this
approach is chosen (and its cost) is spelled out there.

## Distribution: TrollStore

Installed as a `.tipa` via **TrollStore**, which signs with real entitlements —
crucially `dynamic-codesigning`, which grants the **persistent JIT** box64 needs
(`packaging/entitlements.plist`). This retires the single scariest blocker: on a
normal sideload, iOS JIT is fragile-to-impossible; on TrollStore it just works.

## Status

**Stage 0 — planning + foundation.** No emulator runs yet. See
[`ROADMAP.md`](ROADMAP.md) for the staged plan and the honest blocker list.

Nothing in this repo produces a playable build today. Anyone who tells you
otherwise is wrong. The point of the current stage is to get the CPU emulator
(box64) to *cross-compile for iOS at all* — that first attempt surfaces the real
work.

## Why not just recompile? (the native port)

The native arm64 recompile lives in a separate tree and is *one header commit*
from a green iOS build. It has **no emulation tax and no cross-module boundary
tax**, so it is strictly faster than anything in this repo and is the
recommended path if the goal is "play the game well on iOS."

This repo exists for the case where you specifically want to run **stock,
unmodified game binaries** (e.g. to preserve exact mod/Lua-native-module
compatibility) instead of a recompiled engine.

## The one decision everything hangs on

GMod x64 ships as **both** Windows PE and Linux ELF binaries. That choice
determines the entire stack:

| | Windows PE bins | Linux ELF bins *(chosen)* |
|---|---|---|
| OS layer | Wine (Win32 → Darwin) | Linux syscall shim → Darwin |
| Graphics | D3D9 → DXVK → MoltenVK → Metal | OpenGL → Metal (ANGLE/MoltenGL) |
| Precedent on ARM | Winlator-style, very heavy | box64's home turf |
| Verdict | worse road on iOS | **default** |

We target **Linux ELF + box64 + GL→Metal**. Wine-on-iOS is a strictly larger
and less-trodden problem.
