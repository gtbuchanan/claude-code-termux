#!/data/data/com.termux/files/usr/bin/bash
#
# bootstrap.sh — resolve, download, verify, and patch the Claude Code
# linux-arm64 binary so it runs natively on Termux/Android (aarch64).
#
# Installed by the claude-code-termux package. Invoked by postinst (on install)
# and by `claude-code-termux-update`. Two patches are applied to a freshly
# downloaded binary:
#   1. patchelf --set-interpreter → Termux's glibc loader (kernel-direct exec).
#   2. patch-execpath.py → blank the subprocess CLAUDE_CODE_EXECPATH assignment
#      so Claude's embedded-tool re-execs route through the launcher wrapper.
#
# The binary is downloaded directly from Anthropic at run time and patched
# locally; nothing is rehosted here. See the README for the full rationale.
#
# Modes:
#   bootstrap.sh ensure      Ensure a usable binary exists (no-op if present).
#   bootstrap.sh update      Re-fetch only if the resolved version differs from
#                            the installed one (idempotent; safe to schedule).
#   bootstrap.sh --force     Re-download and re-patch the resolved version.
#
set -euo pipefail

DL_BASE='https://downloads.claude.ai/claude-code-releases'
PLATFORM='linux-arm64'

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="${GLIBC_PREFIX:-$PREFIX/glibc}"
PATCHELF="$GLIBC_PREFIX/bin/patchelf"
GLIBC_LD="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"

LIBEXEC="$PREFIX/libexec/claude-code-termux"
OPT_DIR="$PREFIX/opt/claude-code-termux"
CURRENT="$OPT_DIR/current"
CONF="$PREFIX/etc/claude-code-termux.conf"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# curl with built-in resilience to transient network failures: retries on
# timeouts, 5xx, and connection-refused with exponential backoff. A checksum
# mismatch is deliberately NOT retried — that's a bad/tampered file, not a
# transient glitch, so it should fail loudly.
CURL=(curl -fsSL --retry "${CLAUDE_CODE_DL_RETRIES:-3}" --retry-delay 2 --retry-connrefused)

# Config file may set CLAUDE_CODE_VERSION (empty = track latest) and
# CLAUDE_CODE_CACHE_DIR (empty = no cache). Environment variables of the same
# name take precedence over the file.
if [ -r "$CONF" ]; then
  _env_version="${CLAUDE_CODE_VERSION:-}"
  _env_cache="${CLAUDE_CODE_CACHE_DIR:-}"
  # shellcheck source=/dev/null
  . "$CONF"
  [ -n "$_env_version" ] && CLAUDE_CODE_VERSION="$_env_version"
  [ -n "$_env_cache" ] && CLAUDE_CODE_CACHE_DIR="$_env_cache"
fi

resolve_version() {
  local v="${CLAUDE_CODE_VERSION:-}"
  if [ -z "$v" ]; then
    v=$("${CURL[@]}" "$DL_BASE/latest" | tr -d '[:space:]')
  fi
  case "$v" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "unexpected version string: '$v'" ;;
  esac
  printf '%s' "$v"
}

fetch() {
  local version="$1"
  local binary="$OPT_DIR/claude-$version"

  command -v curl >/dev/null 2>&1 || die "missing 'curl' — pkg install curl"
  command -v jq >/dev/null 2>&1 || die "missing 'jq' — pkg install jq"
  command -v python3 >/dev/null 2>&1 || die "missing 'python3' — pkg install python"
  [ -x "$PATCHELF" ] || die "patchelf not found at $PATCHELF — pkg install patchelf-glibc"
  [ -e "$GLIBC_LD" ] || die "glibc loader not found at $GLIBC_LD — pkg install glibc-runner"

  mkdir -p "$OPT_DIR"

  # Patches are applied to a freshly fetched binary only: the execPath patch
  # is not idempotent (it consumes its own anchor), so an already-installed
  # version is left as-is.
  if [ ! -x "$binary" ]; then
    local checksum tmp cache=""
    checksum=$("${CURL[@]}" "$DL_BASE/$version/manifest.json" |
      jq -er --arg p "$PLATFORM" '.platforms[$p].checksum')

    # Optional raw-binary cache (CLAUDE_CODE_CACHE_DIR): skip the multi-MB
    # download on reinstalls / version rollbacks — handy on slow or metered
    # mobile links. The cache holds the verified RAW bytes (pre-patch), so the
    # checksum, patchelf, and execPath patch below still run every time; only
    # the network transfer is skipped.
    [ -n "${CLAUDE_CODE_CACHE_DIR:-}" ] && cache="$CLAUDE_CODE_CACHE_DIR/claude-$version-$PLATFORM"

    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT

    if [ -n "$cache" ] && [ -f "$cache" ] &&
      [ "$(sha256sum "$cache" | cut -d' ' -f1)" = "$checksum" ]; then
      log "Using cached Claude Code $version ($PLATFORM)."
      cp "$cache" "$tmp"
    else
      log "Downloading Claude Code $version ($PLATFORM) from Anthropic…"
      "${CURL[@]}" "$DL_BASE/$version/$PLATFORM/claude" -o "$tmp"
      local actual
      actual=$(sha256sum "$tmp" | cut -d' ' -f1)
      [ "$actual" = "$checksum" ] ||
        die "checksum mismatch for $PLATFORM: expected $checksum, got $actual"
      # Save the verified raw bytes for next time.
      if [ -n "$cache" ]; then
        mkdir -p "$CLAUDE_CODE_CACHE_DIR"
        cp "$tmp" "$cache"
      fi
    fi

    # Point the ELF interpreter at Termux's glibc loader. LD_PRELOAD is cleared
    # so termux-exec's unversioned libc.so text-script does not crash patchelf
    # (itself a glibc binary).
    LD_PRELOAD='' "$PATCHELF" --set-interpreter "$GLIBC_LD" "$tmp"

    # Blank the subprocess CLAUDE_CODE_EXECPATH assignment (python3 is bionic,
    # so no LD_PRELOAD handling is needed here).
    python3 "$LIBEXEC/patch-execpath.py" "$tmp"

    chmod +x "$tmp"
    mv "$tmp" "$binary"
    trap - EXIT
  fi

  ln -sfn "claude-$version" "$CURRENT"

  # Drop older pinned binaries (the symlink keeps the current one).
  find "$OPT_DIR" -mindepth 1 -maxdepth 1 -type f -name 'claude-*' \
    ! -name "claude-$version" -delete

  log "Claude Code $version ready."
}

mode="${1:-ensure}"
case "$mode" in
ensure)
  # A present, executable `current` is not enough: a stock or half-patched
  # binary keeps its +x bit but its ELF interpreter still points at glibc's
  # default loader, which does not exist on Termux, so the kernel rejects the
  # exec with "required file not found". That is exactly the breakage this
  # package exists to fix, and `[ -x ]` can't see it. Verify the interpreter was
  # actually repointed at Termux's glibc loader; repair otherwise (a
  # missing/dangling `current` makes patchelf error → empty → also repairs).
  # LD_PRELOAD is cleared for the same reason as in fetch(): patchelf is a glibc
  # binary. `--force` still covers deeper corruption (correct interpreter, bad
  # body).
  if [ "$(LD_PRELOAD='' "$PATCHELF" --print-interpreter "$CURRENT" 2>/dev/null)" != "$GLIBC_LD" ]; then
    # fetch() only patches a missing binary, so drop the mis-patched one (and the
    # symlink) first, the same as --force, to force a clean re-download + re-patch.
    v="$(resolve_version)"
    rm -f "$OPT_DIR/claude-$v" "$CURRENT"
    fetch "$v"
  fi
  ;;
update)
  # Resolve the target version and re-fetch only when it differs from the
  # installed one (the `current` symlink points at `claude-<version>`). The
  # version check is a single cheap request; the multi-MB download and patch
  # happen only on an actual change, so this is safe to run unattended on a
  # schedule. Use --force to re-apply the same version (e.g. repair).
  v="$(resolve_version)"
  if [ "$(readlink "$CURRENT" 2>/dev/null)" = "claude-$v" ]; then
    log "Claude Code $v already current."
  else
    fetch "$v"
  fi
  ;;
--force | force)
  v="$(resolve_version)"
  rm -f "$OPT_DIR/claude-$v" "$CURRENT"
  fetch "$v"
  ;;
*)
  die "usage: bootstrap.sh [ensure|update|--force]"
  ;;
esac
