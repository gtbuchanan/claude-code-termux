#!/usr/bin/env bash
#
# Run the full build + install + test on your machine, exactly as CI does, in a
# termux/termux-docker:aarch64 container — natively on arm64 hosts, under QEMU
# on others. Requires Docker (Docker Desktop on Windows/macOS, or dockerd on
# Linux).
#
#   scripts/test-docker.sh [version]   # empty → test.sh derives it (run 0)
#
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
version="${1:-}"   # empty → test.sh derives it via version.sh (run number 0 locally)

echo "==> Ensuring aarch64 emulation is registered…"
docker run --rm --privileged tonistiigi/binfmt --install arm64 >/dev/null

echo "==> Building + installing + testing in termux-docker:aarch64 ($version)…"
# Persistent host caches (gitignored) so repeated local runs skip re-downloads:
#   apt/    → Termux apt archive cache (build toolchain + .deb runtime deps)
#   claude/ → the Claude Code binary, via CLAUDE_CODE_CACHE_DIR (raw, pre-patch
#             bytes — patchelf + the execPath patch still run every time)
# CI skips this (native arm64 + fast link); it's purely a local speedup.
mkdir -p "$root/artifacts/cache/apt/partial" "$root/artifacts/cache/claude"
chmod -R 777 "$root/artifacts/cache"

# MSYS_NO_PATHCONV stops Git Bash on Windows from mangling the bind-mount paths.
# Values reach the sanitized-env container as positional args, not via -e.
MSYS_NO_PATHCONV=1 docker run --rm --privileged \
  -v "$root:/src:ro" \
  -v "$root/artifacts/cache/apt:/data/data/com.termux/cache/apt/archives" \
  -v "$root/artifacts/cache/claude:/cache/claude" \
  termux/termux-docker:aarch64 \
  bash -c '
    set -eu
    # Keep downloaded .debs in the host-mounted archive cache across runs.
    printf "APT::Keep-Downloaded-Packages \"true\";\n" \
      > /data/data/com.termux/files/usr/etc/apt/apt.conf.d/99keep-downloads
    cp -r /src ~/work && cd ~/work
    CLAUDE_CODE_CACHE_DIR=/cache/claude bash scripts/test.sh "$1"
  ' test-docker "$version"
