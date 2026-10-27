#!/data/data/com.termux/files/usr/bin/bash
#
# Installer for claude-code-termux. Enables the glibc package repo, then installs
# the .deb with apt, which resolves the package's dependencies (glibc-runner,
# patchelf-glibc, jq) automatically. The package's postinstall then
# downloads + patches the Claude Code binary.
#
#   curl -fsSL https://raw.githubusercontent.com/gtbuchanan/claude-code-termux/main/install.sh | bash
#
# By default it downloads the latest release .deb from GitHub. Set
# CLAUDE_CODE_DEB=<path> to install a local .deb instead — pin to a specific
# release by downloading its .deb from the GitHub releases page and pointing
# CLAUDE_CODE_DEB at it, since the default path always tracks latest. (CI uses
# the same hook to test a freshly-built package, so it exercises the real
# installer — this is the single install path.)
#
# The Claude Code binary is downloaded directly from Anthropic and is not
# redistributed by this project. Your use of Claude Code is governed by
# Anthropic's Commercial Terms of Service:
#   https://www.anthropic.com/legal/commercial-terms
#
REPO="gtbuchanan/claude-code-termux"
API="https://api.github.com/repos/$REPO/releases/latest"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

# Extract the aarch64 .deb's browser_download_url from GitHub release JSON ($1).
# grep/sed, not jq: jq is only pulled in later as a package dependency. `|| true`
# keeps a no-match grep from tripping main's pipefail; main handles the empty.
asset_url() {
  printf '%s' "$1" |
    { grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*_aarch64\.deb"' || true; } |
    head -1 |
    sed -E 's/.*"(https[^"]+)"$/\1/'
}

# Extract the aarch64 .deb asset's sha256 digest from GitHub release JSON ($1).
# Digests are per-asset, so bind to the same asset asset_url picks rather than
# grabbing the first digest in the document: flatten newlines, split the asset
# array into one object per line, select the .deb object by its URL, then read
# that object's digest. grep/sed, not jq (only pulled in later as a package
# dependency). GitHub records a sha256 for every asset and this repo's releases
# are immutable, so it can't change after publish. `|| true` tolerates a
# no-match; an absent digest makes main abort (it only fetches the latest
# release, which always carries one).
asset_digest() {
  printf '%s' "$1" |
    tr '\n' ' ' |
    sed -E 's/\}[[:space:]]*,[[:space:]]*\{/}\n{/g' |
    { grep -E '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*_aarch64\.deb"' || true; } |
    head -1 |
    { grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' || true; } |
    head -1 |
    sed -E 's/.*"sha256:([0-9a-f]{64})".*/\1/'
}

# Succeed when this is the Google Play build of Termux, given the app's
# TERMUX_VERSION ($1) and the concatenated apt sources ($2). That build cannot
# run Claude Code whatever its repository: its target SDK forbids executing
# app-data files, and termux-exec's /system/bin/linker64 route loads bionic
# programs only, so the glibc loader cannot start. Its termux.net repository
# also omits glibc-repo. The app sets TERMUX_VERSION to its versionName,
# googleplay.<date>, and never sets TERMUX_APK_RELEASE; the termux.net source
# catches it in an environment that did not inherit TERMUX_VERSION. A source
# commented out with # is one apt ignores, so it does not count.
play_build() {
  case "$1" in googleplay.*) return 0 ;; esac
  printf '%s\n' "$2" | grep -qE '^[^#]*://termux\.net([/[:space:]]|$)'
}

# Explain why apt cannot find glibc-repo, given the exit status of the
# preceding `apt-get update` ($1). Every build that reaches this check has
# glibc-repo in termux-main, so after a good refresh a miss means the mirror
# lacks it. After a failed one the index may be missing or stale, which says
# nothing about the mirror.
glibc_repo_missing_reason() {
  if [ "$1" -eq 0 ]; then
    echo "this Termux mirror has no glibc-repo package. Pick another mirror with termux-change-repo, then re-run this installer."
  else
    echo "apt-get update failed (exit $1), so apt cannot see glibc-repo. Fix the error above (network, signing key, or an unreachable mirror: termux-change-repo), then re-run this installer."
  fi
}

main() {
  set -euo pipefail

  command -v curl >/dev/null 2>&1 || die "missing 'curl' — pkg install curl"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer is for Termux."

  # Only the files apt reads: sources.list.d also collects backups like
  # *.list.save, which apt skips by extension.
  local apt_dir="${PREFIX:-/data/data/com.termux/files/usr}/etc/apt"
  if play_build "${TERMUX_VERSION:-}" \
    "$(cat "$apt_dir"/sources.list "$apt_dir"/sources.list.d/*.list \
      "$apt_dir"/sources.list.d/*.sources 2>/dev/null || true)"; then
    die "Termux from Google Play cannot run glibc programs, which Claude Code is. Install Termux from F-Droid (https://f-droid.org/packages/com.termux/) or GitHub (https://github.com/termux/termux-app/releases) instead; the builds are signed differently, so uninstall the Play build first (back up \$HOME), then re-run this installer."
  fi

  # Not `local`: the EXIT trap below fires after main() returns and reads $deb,
  # which a local would put out of scope (unbound under set -u).
  deb="${CLAUDE_CODE_DEB:-}"
  if [ -n "$deb" ]; then
    [ -f "$deb" ] || die "CLAUDE_CODE_DEB not found: $deb"
    log "Installing local package $deb"
  else
    log "Resolving the latest release of $REPO…"
    local api url digest actual
    api=$(curl -fsSL "$API") ||
      die "could not reach the GitHub API (network down or rate limited)."
    url=$(asset_url "$api")
    [ -n "$url" ] || die "no aarch64 .deb asset found in the latest release."

    deb=$(mktemp --suffix=.deb)
    trap 'rm -f -- "$deb"' EXIT
    log "Downloading $url"
    curl -fsSL "$url" -o "$deb"

    # Verify the download against the release asset's digest before install,
    # since the .deb runs a postinst that patches binaries. A missing digest
    # aborts too: install.sh only fetches the latest release, which always
    # carries one, so its absence means tampered or unexpected metadata — not a
    # legitimately undigested asset — and skipping the check would defeat it.
    digest=$(asset_digest "$api")
    [ -n "$digest" ] ||
      die "no sha256 digest for $(basename "$url") in the release metadata; refusing to install unverified."
    log "Verifying checksum…"
    actual=$(sha256sum "$deb" | cut -d' ' -f1)
    [ "$actual" = "$digest" ] ||
      die "checksum mismatch for $(basename "$url"): expected $digest, got $actual."
    log "Checksum OK."
  fi

  # glibc-runner and patchelf-glibc live in the glibc-packages repo, which the
  # `glibc-repo` package enables. It must be added (and the index refreshed)
  # BEFORE installing the package — apt resolves the whole dependency graph up
  # front, so a repo added mid-transaction wouldn't be consulted. A failed
  # refresh is tolerated while a cached index still lists glibc-repo; without
  # it the install aborts here with the remedy, before apt fails on it.
  log "Enabling the glibc package repo…"
  local update_rc=0
  apt-get update -y || update_rc=$?
  apt-cache show glibc-repo >/dev/null 2>&1 ||
    die "$(glibc_repo_missing_reason "$update_rc")"
  apt-get install -y glibc-repo
  apt-get update -y

  # apt reads the package's Depends and pulls glibc-runner, patchelf-glibc, and
  # jq automatically (dpkg -i would not).
  log "Installing (apt resolves dependencies)…"
  apt-get install -y "$deb"

  log "Done. Run 'claude' to start."
}

# Run the installer, unless this file is being sourced by the unit test for its
# helper functions (which sets CLAUDE_CODE_INSTALL_LIB). A piped `curl … | bash`
# leaves the var unset — and since BASH_SOURCE is empty in that case the usual
# "${BASH_SOURCE[0]}" = "$0" guard would wrongly skip the install — so the
# normal one-liner still runs main.
[ -n "${CLAUDE_CODE_INSTALL_LIB:-}" ] || main "$@"
