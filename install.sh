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
set -euo pipefail

REPO="gtbuchanan/claude-code-termux"
API="https://api.github.com/repos/$REPO/releases/latest"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "missing 'curl' — pkg install curl"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer is for Termux."

deb="${CLAUDE_CODE_DEB:-}"
if [ -n "$deb" ]; then
  [ -f "$deb" ] || die "CLAUDE_CODE_DEB not found: $deb"
  log "Installing local package $deb"
else
  log "Resolving the latest release of $REPO…"
  api=$(curl -fsSL "$API") ||
    die "could not reach the GitHub API (network down or rate limited)."
  # Pull the .deb's download URL and its asset digest out of the release JSON.
  # jq isn't a guaranteed dependency yet here (apt installs it later), so this
  # stays grep/sed. `|| true`: a no-match grep exits 1, which under pipefail
  # would abort; an absent value is handled by the checks below.
  url=$(printf '%s' "$api" |
    { grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*_aarch64\.deb"' || true; } |
    head -1 |
    sed -E 's/.*"(https[^"]+)"$/\1/')
  [ -n "$url" ] ||
    die "no aarch64 .deb asset in the latest release (GitHub API error or rate limit?)."

  deb=$(mktemp --suffix=.deb)
  trap 'rm -f "$deb"' EXIT
  log "Downloading $url"
  curl -fsSL "$url" -o "$deb"

  # Verify the download against the release asset's digest. GitHub records a
  # sha256 for every release asset, and this repo uses immutable releases, so it
  # can't change after publish. A mismatch aborts before install, since the .deb
  # runs a postinst and patches binaries. The release publishes a single .deb
  # asset, so its digest is the only one in the JSON. (Assets from before GitHub
  # exposed digests fall back to a warning.)
  digest=$(printf '%s' "$api" |
    { grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]{64}"' || true; } |
    head -1 |
    sed -E 's/.*"sha256:([0-9a-f]{64})".*/\1/')
  if [ -n "$digest" ]; then
    log "Verifying checksum…"
    actual=$(sha256sum "$deb" | cut -d' ' -f1)
    [ "$actual" = "$digest" ] ||
      die "checksum mismatch for $(basename "$url"): expected $digest, got $actual."
    log "Checksum OK."
  else
    log "warning: release asset has no digest; skipping checksum verification."
  fi
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
