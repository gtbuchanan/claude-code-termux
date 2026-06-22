#!/data/data/com.termux/files/usr/bin/bash
#
# Compile the C launcher wrapper (and its uname shim) for aarch64 Termux. Must
# run in an environment whose toolchain targets Termux's bionic — i.e. inside
# `termux/termux-docker:aarch64` (CC=clang) — so the resulting ELF matches the
# device. The outputs are written to build/ and staged into the .deb by
# build-deb.sh. (Termux-only, hence the absolute Termux shebang.)
#
set -euo pipefail

PREFIX=/data/data/com.termux/files/usr
# The wrapper execs the `current` symlink that bootstrap.sh keeps pointing at
# the patched binary, sets TMPDIR to the Termux prefix tmp dir (Termux has no
# writable /tmp), and LD_PRELOADs the uname shim (see src/uname-shim.c). All
# three are baked in at compile time. UNAME_SHIM must match the install path
# build-deb.sh stages the .so to.
BINARY="$PREFIX/opt/claude-code-termux/current"
TMPDIR_PATH="$PREFIX/tmp"
UNAME_SHIM="$PREFIX/lib/claude-code-termux/uname-spoof.so"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/artifacts/build"
mkdir -p "$out"

: "${CC:=cc}"

# The uname shim is freestanding (-nostdlib -ffreestanding): no libc of its own,
# so the glibc binary's ld.so loads it as an LD_PRELOAD regardless of the bionic
# toolchain that built it, and its raw uname syscall never recurses into the
# symbol it interposes.
"$CC" -O2 -Wall -Wextra -Werror -shared -fPIC -nostdlib -ffreestanding \
  -fno-stack-protector -o "$out/uname-spoof.so" "$root/src/uname-shim.c"

"$CC" -O2 -Wall -Wextra -Werror -DBINARY="\"$BINARY\"" -DTMPDIR_PATH="\"$TMPDIR_PATH\"" \
  -DUNAME_SHIM="\"$UNAME_SHIM\"" \
  -o "$out/claude" "$root/src/claude-wrapper.c"

echo "$out/claude"
