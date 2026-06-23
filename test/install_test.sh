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

# A release-JSON shape mirroring GitHub's, with a decoy asset (no .deb suffix,
# its own distinct digest) ordered before the aarch64 .deb so the selectors must
# discriminate by asset — not just grab the first url/digest in the document.
release_json() {
  cat <<'EOF'
{
  "assets": [
    {
      "name": "release-notes.txt",
      "browser_download_url": "https://github.com/gtbuchanan/claude-code-termux/releases/download/v2026.6.19/release-notes.txt",
      "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    },
    {
      "name": "claude-code-termux_2026.6.19_aarch64.deb",
      "browser_download_url": "https://github.com/gtbuchanan/claude-code-termux/releases/download/v2026.6.19/claude-code-termux_2026.6.19_aarch64.deb",
      "digest": "sha256:6c5280d0a9fa52138097035b298e03fcb40e61001350a3492a8d70c35b2805a8"
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

test_asset_digest_extracts_sha256() {
  assertEquals 'extracts the .deb asset sha256 digest (bare hex, no prefix)' \
    '6c5280d0a9fa52138097035b298e03fcb40e61001350a3492a8d70c35b2805a8' \
    "$(asset_digest "$(release_json)")"
}

# Run helper $1 (asset_url|asset_digest) on JSON $3 under pipefail — as main()
# does — and assert no output AND a 0 exit. Empty-with-success is what proves
# the `|| true` guard: without it the no-match grep's non-zero status would trip
# pipefail and abort the install.
assert_empty_under_pipefail() { # $1 = helper, $2 = message, $3 = release JSON
  local out rc
  out="$(
    set -o pipefail
    "$1" "$3"
  )"
  rc=$?
  assertEquals "$2" '' "$out"
  assertEquals "$2 (exits 0 under pipefail)" 0 "$rc"
}

test_asset_url_empty_when_no_aarch64_deb() {
  assert_empty_under_pipefail asset_url 'empty when the release has no aarch64 .deb asset' \
    '{"assets":[{"browser_download_url":"https://example.com/x.txt"}]}'
}

test_asset_url_empty_on_non_json() {
  assert_empty_under_pipefail asset_url 'empty on a non-JSON blob' 'this is not json'
}

test_asset_digest_empty_when_absent() {
  assert_empty_under_pipefail asset_digest 'empty when the .deb asset has no digest' \
    '{"assets":[{"browser_download_url":"https://example.com/x_aarch64.deb"}]}'
}

# shUnit2 hands control here: it discovers the test_* functions above and prints
# the summary.
# shellcheck source=/dev/null
. ./vendor/shunit2
