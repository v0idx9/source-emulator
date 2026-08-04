#!/usr/bin/env bash
# Stage-0 exit step: ATTEMPT an iOS arm64 cross-compile of box64.
#
# This is EXPECTED TO FAIL. box64 upstream targets arm64 Linux, not Darwin/iOS.
# The point is to surface the concrete port blockers (Mach-O host, Darwin mmap
# and thread primitives, signal handling, the iOS JIT write path) so Stage 1 has
# a real task list instead of a guess. See ARCHITECTURE.md section 2.
#
# Requires macOS + Xcode. On any other host it stops early and says so, on
# purpose — execution can only be proven on real hardware.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/third_party/box64"
BUILD="${ROOT}/build/box64-ios"

if [ ! -d "${SRC}" ]; then
	echo "box64 source missing; run scripts/fetch-box64.sh first." >&2
	exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
	echo "NOTE: not on macOS — the iOS SDK/toolchain is unavailable here." >&2
	echo "This script only does something real on a macOS + Xcode host." >&2
	echo "Run it there (or in CI on macos-14) to collect the port blockers." >&2
	exit 0
fi

IOS_MIN="${IOS_MIN_VERSION:-14.0}"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"

mkdir -p "${BUILD}"

# box64 is a CMake project. We feed it an iOS toolchain and capture whatever it
# rejects. --toolchain would be cleaner long-term; inline flags are enough to
# reach (and log) the first wall.
set +e
cmake -S "${SRC}" -B "${BUILD}" \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_SYSROOT="${SDKROOT}" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN}" \
	-DARM_DYNAREC=ON \
	-DCMAKE_BUILD_TYPE=Release \
	2>&1 | tee "${BUILD}/configure.log"
cfg_rc=${PIPESTATUS[0]}
set -e

echo
if [ "${cfg_rc}" -ne 0 ]; then
	echo "==> configure failed (expected). Blockers captured in:"
	echo "    ${BUILD}/configure.log"
	echo "    Triage these into ROADMAP Stage 1 tasks."
	exit 0
fi

echo "==> configure succeeded unexpectedly — try building and log the breaks:"
set +e
cmake --build "${BUILD}" -j"$(sysctl -n hw.ncpu)" 2>&1 | tee "${BUILD}/build.log"
echo "==> build attempt logged to ${BUILD}/build.log"
