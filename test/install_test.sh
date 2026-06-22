#!/usr/bin/env bash
#
# Hermetic unit tests for install.sh's pure helpers. Sources install.sh with
# CLAUDE_CODE_INSTALL_LIB set so its main() does NOT run (no network, no apt),
# then drives the helpers directly. Runs anywhere via `mise run test:shunit2`
# — no Termux, no Docker, milliseconds.
#
# Built on the vendored shUnit2 (vendor/shunit2): each behavior is a `test_*`
# function; shUnit2 discovers them and prints the run summary. Like e2e.sh, this
# deliberately does NOT `set -e` (errexit fights the framework) — and sourcing
# install.sh under the lib guard skips its `set -euo pipefail` (that lives in
# main()), so the test shell stays errexit-free.

# Resolve install.sh and vendor/shunit2 against the repo root regardless of cwd.
cd "$(dirname "$0")/.." || exit 1

# Source the installer for its functions only; the guard keeps main() — and its
# strict mode — from running.
# shellcheck source=/dev/null
CLAUDE_CODE_INSTALL_LIB=1 . ./install.sh

# A release-JSON shape mirroring GitHub's, with a decoy asset before the aarch64
# .deb so the selector has to discriminate rather than grab the first URL.
release_json() {
  cat <<'EOF'
{
  "assets": [
    {
      "name": "SHA256SUMS",
      "browser_download_url": "https://github.com/gtbuchanan/claude-code-termux/releases/download/v2026.6.19/SHA256SUMS"
    },
    {
      "name": "claude-code-termux_2026.6.19_aarch64.deb",
      "browser_download_url": "https://github.com/gtbuchanan/claude-code-termux/releases/download/v2026.6.19/claude-code-termux_2026.6.19_aarch64.deb"
    }
  ]
}
EOF
}

test_asset_url_extracts_aarch64_deb() {
  assertEquals 'picks the aarch64 .deb download URL over a decoy asset' \
    'https://github.com/gtbuchanan/claude-code-termux/releases/download/v2026.6.19/claude-code-termux_2026.6.19_aarch64.deb' \
    "$(asset_url "$(release_json)")"
}

test_asset_url_empty_when_no_aarch64_deb() {
  assertEquals 'empty when the release has no aarch64 .deb asset' '' \
    "$(asset_url '{"assets":[{"browser_download_url":"https://example.com/x.txt"}]}')"
}

test_asset_url_empty_on_non_json() {
  assertEquals 'empty (no crash under pipefail) on a non-JSON blob' '' \
    "$(asset_url 'this is not json')"
}

# shUnit2 hands control here: it discovers the test_* functions above and prints
# the summary.
# shellcheck source=/dev/null
. ./vendor/shunit2
