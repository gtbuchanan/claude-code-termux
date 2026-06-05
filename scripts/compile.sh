#!/data/data/com.termux/files/usr/bin/bash
#
# Runs INSIDE termux/termux-docker:aarch64 (or natively on a Termux device).
# Compiles the launcher wrapper with Termux's own clang and assembles the .deb —
# the compile half of the pipeline. The e2e half (install + assert) lives in
# scripts/e2e.sh and runs against this script's output.
#
#   bash scripts/compile.sh [version]   # empty → version.sh derives the CalVer
#
set -euxo pipefail

VERSION="${1:-$(bash "$(dirname "$0")/version.sh")}"

# --- Compile toolchain ------------------------------------------------------
# A C compiler (the wrapper) + dpkg-deb (packaging) — NOT the package's runtime
# deps. A fresh termux-docker has no apt mirror selected, so `pkg update` picks
# one before the install; a provisioned device that already has both tools skips
# straight to the compile.
if ! command -v clang >/dev/null || ! command -v dpkg-deb >/dev/null; then
  pkg update
  apt-get install -y clang dpkg
fi

# --- Compile + package ------------------------------------------------------
# Run under Termux's restrictive default umask (077) to prove build-deb.sh
# normalizes it — termux-docker runs at 022, which masked a real-device dpkg-deb
# failure (0700 DEBIAN control dir, outside the allowed 0755..0775). Scoped to a
# subshell so the umask change can't leak into later commands when this script
# is sequenced with others in a single shell.
(
  umask 077
  CC=clang "$(dirname "$0")/build-wrapper.sh"
  "$(dirname "$0")/build-deb.sh" "$VERSION"
)
