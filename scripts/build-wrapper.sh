#!/data/data/com.termux/files/usr/bin/bash
#
# Compile the C launcher wrapper for aarch64 Termux. Must run in an
# environment whose toolchain targets Termux's bionic — i.e. inside
# `termux/termux-docker:aarch64` (CC=clang) — so the resulting ELF matches the
# device. The compiled binary is written to build/claude and staged into the
# .deb by build-deb.sh. (Termux-only, hence the absolute Termux shebang.)
#
set -euo pipefail

PREFIX=/data/data/com.termux/files/usr
# The wrapper execs the `current` symlink that bootstrap.sh keeps pointing at
# the patched binary, and sets TMPDIR to the Termux prefix tmp dir (Termux has
# no writable /tmp). Both are baked in at compile time.
BINARY="$PREFIX/opt/claude-code-termux/current"
TMPDIR_PATH="$PREFIX/tmp"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/artifacts/build"
mkdir -p "$out"

: "${CC:=cc}"
"$CC" -O2 -Wall -Wextra -DBINARY="\"$BINARY\"" -DTMPDIR_PATH="\"$TMPDIR_PATH\"" \
  -o "$out/claude" "$root/src/claude-wrapper.c"

echo "$out/claude"
