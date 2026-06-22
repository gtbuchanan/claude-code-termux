#!/data/data/com.termux/files/usr/bin/bash
#
# Installer for claude-code-termux. Enables the glibc package repo, then installs
# the .deb with apt, which resolves the package's dependencies (glibc-runner,
# patchelf-glibc, jq, python3) automatically. The package's postinstall then
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

main() {
  set -euo pipefail

  command -v curl >/dev/null 2>&1 || die "missing 'curl' — pkg install curl"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer is for Termux."

  # Not `local`: the EXIT trap below fires after main() returns and reads $deb,
  # which a local would put out of scope (unbound under set -u).
  deb="${CLAUDE_CODE_DEB:-}"
  if [ -n "$deb" ]; then
    [ -f "$deb" ] || die "CLAUDE_CODE_DEB not found: $deb"
    log "Installing local package $deb"
  else
    log "Resolving the latest release of $REPO…"
    local api url
    api=$(curl -fsSL "$API") ||
      die "could not reach the GitHub API (network down or rate limited)."
    url=$(asset_url "$api")
    [ -n "$url" ] || die "no aarch64 .deb asset found in the latest release."

    deb=$(mktemp --suffix=.deb)
    trap 'rm -f -- "$deb"' EXIT
    log "Downloading $url"
    curl -fsSL "$url" -o "$deb"
  fi

  # glibc-runner and patchelf-glibc live in the glibc-packages repo, which the
  # `glibc-repo` package enables. It must be added (and the index refreshed)
  # BEFORE installing the package — apt resolves the whole dependency graph up
  # front, so a repo added mid-transaction wouldn't be consulted.
  log "Enabling the glibc package repo…"
  apt-get update -y || true
  apt-get install -y glibc-repo
  apt-get update -y

  # apt reads the package's Depends and pulls glibc-runner, patchelf-glibc, jq,
  # and python3 automatically (dpkg -i would not).
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
