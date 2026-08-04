#!/usr/bin/env bash
# Fetch box64 (the x86-64 -> arm64 JIT) at a pinned commit.
# box64 is the CPU-emulation layer; see ARCHITECTURE.md section 2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/third_party/box64"

# Pin so the porting notes stay valid. Bump deliberately, not incidentally.
BOX64_REPO="https://github.com/ptitSeb/box64.git"
BOX64_REF="${BOX64_REF:-v0.3.2}"

mkdir -p "${ROOT}/third_party"

if [ -d "${SRC}/.git" ]; then
	echo "==> box64 already present at ${SRC} ($(git -C "${SRC}" describe --tags --always))"
	exit 0
fi

echo "==> cloning box64 ${BOX64_REF}"
git clone --depth 1 --branch "${BOX64_REF}" "${BOX64_REPO}" "${SRC}"
echo "==> box64 at $(git -C "${SRC}" rev-parse --short HEAD)"
echo "    Reference port to study: the Android arm64 target (closest to iOS)."
