#!/data/data/com.termux/files/usr/bin/bash
#
# Compile the C launcher wrapper (and its shims) for aarch64 Termux. Must
# run in an environment whose toolchain targets Termux's bionic — i.e. inside
# `termux/termux-docker:aarch64` (CC=clang) — so the resulting ELF matches the
# device. The outputs are written to build/ and staged into the .deb by
# build-deb.sh. (Termux-only, hence the absolute Termux shebang.)
#
set -euo pipefail

PREFIX=/data/data/com.termux/files/usr
# The wrapper execs the `current` symlink that bootstrap.sh keeps pointing at
# the patched binary, sets TMPDIR to the Termux prefix tmp dir (Termux has no
# writable /tmp), and LD_PRELOADs its shims (see src/*-shim.c). All are baked in
# at compile time; the shim paths must match where build-deb.sh stages the .so
# files.
BINARY="$PREFIX/opt/claude-code-termux/current"
TMPDIR_PATH="$PREFIX/tmp"
UNAME_SHIM="$PREFIX/lib/claude-code-termux/uname-spoof.so"
RESOLV_SHIM="$PREFIX/lib/claude-code-termux/resolv-redirect.so"
EXECPATH_SHIM="$PREFIX/lib/claude-code-termux/execpath-redirect.so"
# Redirect the absolute /etc/resolv.conf (absent on Android) to the prefix copy.
RESOLV_SRC="/etc/resolv.conf"
RESOLV_DST="$PREFIX/etc/resolv.conf"
# Where the execpath shim points Claude's embedded-tool re-execs: the launcher
# this same script compiles, which build-deb.sh stages to $PREFIX/bin/claude.
LAUNCHER_PATH="$PREFIX/bin/claude"

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

# The resolv shim is freestanding too; it references dlsym (resolved from
# libc.so.6 — deliberately NO -ldl, so no DT_NEEDED; see src/resolv-shim.c) and
# needs -fno-builtin so clang doesn't rewrite the interposed fopen/open calls.
"$CC" -O2 -Wall -Wextra -Werror -shared -fPIC -nostdlib -ffreestanding \
  -fno-stack-protector -fno-builtin \
  -DRESOLV_SRC="\"$RESOLV_SRC\"" -DRESOLV_DST="\"$RESOLV_DST\"" \
  -o "$out/resolv-redirect.so" "$root/src/resolv-shim.c"

# The execpath shim is freestanding on the same terms as the resolv shim (dlsym
# resolved from libc.so.6, no -ldl, so no DT_NEEDED). -fno-builtin keeps clang
# from rewriting the interposed exec/spawn calls.
"$CC" -O2 -Wall -Wextra -Werror -shared -fPIC -nostdlib -ffreestanding \
  -fno-stack-protector -fno-builtin \
  -DLAUNCHER_PATH="\"$LAUNCHER_PATH\"" \
  -o "$out/execpath-redirect.so" "$root/src/execpath-shim.c"

"$CC" -O2 -Wall -Wextra -Werror -DBINARY="\"$BINARY\"" -DTMPDIR_PATH="\"$TMPDIR_PATH\"" \
  -DUNAME_SHIM="\"$UNAME_SHIM\"" -DRESOLV_SHIM="\"$RESOLV_SHIM\"" \
  -DEXECPATH_SHIM="\"$EXECPATH_SHIM\"" \
  -o "$out/claude" "$root/src/claude-wrapper.c"

echo "$out/claude"
