#!/usr/bin/env bash
#
# Run one of the termux-side pipeline scripts (compile.sh, e2e.sh) on a non-
# Termux host in a termux/termux-docker:aarch64 container — natively on arm64
# hosts, under QEMU on others. This is the dev-host / CI entrypoint the compile
# and test:e2e mise tasks dispatch to; on a Termux device the scripts run
# directly. Requires Docker (Docker Desktop on Windows/macOS, or dockerd).
#
#   scripts/docker-run.sh <script> [version]
#   scripts/docker-run.sh compile.sh        # empty version → version.sh
#   scripts/docker-run.sh e2e.sh
#
# GITHUB_RUN_NUMBER (version.sh's CalVer counter) and CLAUDE_CODE_VERSION (the
# Claude Code build to download/test, empty = latest) are read from this
# script's environment and forwarded into the container — `docker run -e` can't
# reach it because termux-docker's entrypoint sanitizes the environment.
#
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/docker-run.sh <compile.sh|e2e.sh> [version]" >&2
  exit 2
fi
script="$1"
version="${2:-}" # positional override → script's $1; empty → version.sh
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# QEMU is only needed off arm64; the CI runner and Apple Silicon run the aarch64
# image natively, so skip the (privileged, image-pulling) binfmt registration.
case "$(uname -m)" in
aarch64 | arm64) ;;
*)
  echo "==> Registering aarch64 emulation…"
  docker run --rm --privileged tonistiigi/binfmt --install arm64 >/dev/null
  ;;
esac

echo "==> Running scripts/$script in termux-docker:aarch64 (${version:-version.sh})…"
# Gitignored host dirs, bind-mounted so state survives across container runs:
#   artifacts/        → writable overlay on the read-only source, so the .deb a
#                       `compile` run produces is visible to a later `e2e` run
#   cache/apt/        → Termux apt archive cache (toolchain + .deb runtime deps)
#   cache/claude/     → the Claude Code binary, via CLAUDE_CODE_CACHE_DIR (raw,
#                       pre-patch bytes — patchelf + the execPath patch still run)
mkdir -p \
  "$root/artifacts/build" "$root/artifacts/packages" \
  "$root/artifacts/cache/apt/partial" "$root/artifacts/cache/claude"
chmod -R 777 "$root/artifacts/build" "$root/artifacts/packages" "$root/artifacts/cache"

# --privileged is required by termux-docker (not just for binfmt): its entrypoint
# does namespace/mount setup and the image expects Android-runtime syscalls.
# MSYS_NO_PATHCONV stops Git Bash on Windows from mangling the bind-mount paths.
# Host values reach the sanitized-env container as positional args, then get
# re-exported inside. /src is read-only; only artifacts/ is writable (the overlay
# mount), keeping the source tree pristine.
MSYS_NO_PATHCONV=1 docker run --rm --privileged \
  -v "$root:/src:ro" \
  -v "$root/artifacts:/src/artifacts" \
  -v "$root/artifacts/cache/apt:/data/data/com.termux/cache/apt/archives" \
  -v "$root/artifacts/cache/claude:/cache/claude" \
  termux/termux-docker:aarch64 \
  bash -c '
    set -eu
    # Keep downloaded .debs in the host-mounted archive cache across runs.
    printf "APT::Keep-Downloaded-Packages \"true\";\n" \
      > /data/data/com.termux/files/usr/etc/apt/apt.conf.d/99keep-downloads
    GITHUB_RUN_NUMBER="$2" CLAUDE_CODE_VERSION="$3" CLAUDE_CODE_CACHE_DIR=/cache/claude \
      bash "/src/scripts/$1" "$4"
  ' docker-run "$script" "${GITHUB_RUN_NUMBER:-}" "${CLAUDE_CODE_VERSION:-}" "$version"
