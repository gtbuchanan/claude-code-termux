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
# writable /tmp), and LD_PRELOADs two shims (see src/uname-shim.c and
# src/resolv-shim.c). All are baked in at compile time. UNAME_SHIM/RESOLV_SHIM
# must match the install paths build-deb.sh stages the .so files to.
BINARY="$PREFIX/opt/claude-code-termux/current"
TMPDIR_PATH="$PREFIX/tmp"
UNAME_SHIM="$PREFIX/lib/claude-code-termux/uname-spoof.so"
RESOLV_SHIM="$PREFIX/lib/claude-code-termux/resolv-redirect.so"
# c-ares reads the absolute /etc/resolv.conf, absent on Android; the shim
# redirects it to the Termux prefix copy (present, reachable). See #25.
RESOLV_SRC="/etc/resolv.conf"
RESOLV_DST="$PREFIX/etc/resolv.conf"

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

# The resolv shim is freestanding too, but must call the real fopen/open (the
# fopen family returns an opaque glibc FILE*), so it references dlsym — left as
# an undefined symbol that glibc's ld.so resolves from libc.so.6 (merged since
# 2.34). Deliberately NO -ldl: that would record a DT_NEEDED libdl.so Termux's
# glibc can't satisfy (see src/resolv-shim.c). -fno-builtin so clang doesn't
# rewrite the interposed calls.
"$CC" -O2 -Wall -Wextra -Werror -shared -fPIC -nostdlib -ffreestanding \
  -fno-stack-protector -fno-builtin \
  -DRESOLV_SRC="\"$RESOLV_SRC\"" -DRESOLV_DST="\"$RESOLV_DST\"" \
  -o "$out/resolv-redirect.so" "$root/src/resolv-shim.c"

"$CC" -O2 -Wall -Wextra -Werror -DBINARY="\"$BINARY\"" -DTMPDIR_PATH="\"$TMPDIR_PATH\"" \
  -DUNAME_SHIM="\"$UNAME_SHIM\"" -DRESOLV_SHIM="\"$RESOLV_SHIM\"" \
  -o "$out/claude" "$root/src/claude-wrapper.c"

echo "$out/claude"
