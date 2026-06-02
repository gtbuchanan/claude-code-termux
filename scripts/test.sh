#!/data/data/com.termux/files/usr/bin/bash
#
# Runs INSIDE termux/termux-docker:aarch64. Compiles the launcher wrapper with
# Termux's own clang, builds the .deb, installs it via install.sh (exercising
# real dependency resolution), and tests the behaviors this package fixes. Set
# TEST_RUN_CLAUDE=1 to exec the patched binary (grep/find dispatch, startup).
# Invoked from the repo root (CI and scripts/test-docker.sh).
#
#   bash scripts/test.sh <version>
#
set -euxo pipefail

VERSION="${1:-$(bash "$(dirname "$0")/version.sh")}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# --- Build toolchain (CI-only) ---------------------------------------------
# A fresh termux-docker has no mirror selected; `pkg update` picks one. Then
# install the build-time tools (NOT package deps): C compiler + packaging tool.
pkg update
apt-get install -y clang dpkg

# --- Build -----------------------------------------------------------------
# Build under Termux's restrictive default umask (077) to prove build-deb.sh
# normalizes it — termux-docker runs at 022, which masked a real-device dpkg-deb
# failure (0700 DEBIAN control dir, outside the allowed 0755..0775). Scoped to a
# subshell so the install + assert phases below run at the inherited umask,
# exactly as a user's install does (dpkg restores packaged file modes anyway).
(
  umask 077
  CC=clang ./scripts/build-wrapper.sh
  ./scripts/build-deb.sh "$VERSION"
)

# --- Install via the real installer ----------------------------------------
# Reuse install.sh (the single install path) against the freshly built .deb, so
# CI exercises the actual installer: glibc-repo enablement + apt dependency
# resolution. Settings are merged (not skipped) so we can verify them below.
deb=$(ls "$PWD"/artifacts/packages/*.deb)
CLAUDE_CODE_DEB="$deb" bash install.sh

# --- Layout assertions -----------------------------------------------------
elf_magic() { od -An -tx1 -N4 "$1" | tr -d ' \n'; }

test -x "$PREFIX/bin/claude"
[ "$(elf_magic "$PREFIX/bin/claude")" = "7f454c46" ] \
  || { echo "wrapper is not an ELF binary"; exit 1; }
test -x "$PREFIX/libexec/claude-code-termux/bootstrap.sh"
test -f "$PREFIX/libexec/claude-code-termux/patch-execpath.py"

# Runtime deps pulled by apt:
command -v jq      >/dev/null
command -v python3 >/dev/null
test -x "$PREFIX/glibc/bin/patchelf"

# postinst downloaded + patched the binary:
test -x "$PREFIX/opt/claude-code-termux/current"
[ "$(elf_magic "$PREFIX/opt/claude-code-termux/current")" = "7f454c46" ] \
  || { echo "patched binary is not an ELF"; exit 1; }

# --- settings.json merge (the shebang fix's mechanism) ---------------------
# postinst writes the LD_PRELOAD re-export — so Claude's subprocesses inherit
# termux-exec and `#!/usr/bin/env …` shebangs resolve — and disables autoUpdates.
settings="${HOME}/.claude/settings.json"
test -f "$settings"
jq -e '.autoUpdates == false' "$settings" >/dev/null
jq -e '.env.LD_PRELOAD | test("libtermux-exec")' "$settings" >/dev/null

# --- Behavior tests (the fixes) --------------------------------------------
assert_contains() { # <needle> <haystack>
  case "$2" in
    *"$1"*) ;;
    *) echo "FAIL: expected '$1' in output: $2" >&2; exit 1 ;;
  esac
}

# Startup.
claude --version

# grep/find dispatch: Claude routes its embedded tools by argv[0]. The compiled
# wrapper must preserve argv[0] through execv for this to reach ripgrep/bfs —
# the core fix. A bash wrapper would arrive as argv[0]=bash and never dispatch.
assert_contains ripgrep "$( (exec -a rg  "$PREFIX/bin/claude" --version) 2>&1 || true)"
assert_contains bfs     "$( (exec -a bfs "$PREFIX/bin/claude" --version) 2>&1 || true)"

# LD_PRELOAD clearing: termux-exec is preloaded into every Termux shell (its lib
# always ships with the termux-exec package). The wrapper must unset it before
# exec'ing the glibc binary, or ld.so crashes on termux-exec's text-script
# libc.so. A clean startup with it preloaded proves the unset.
lib="$PREFIX/lib/libtermux-exec-ld-preload.so"
test -e "$lib"
LD_PRELOAD="$lib" "$PREFIX/bin/claude" --version >/dev/null

# TMPDIR injection: Termux has no writable /tmp, so the wrapper sets TMPDIR +
# CLAUDE_CODE_TMPDIR (only when unset). Compile a probe whose BINARY is `env` so
# we can read the environment the wrapper hands to the exec'd process. The probe
# must be named `env`: the wrapper preserves argv[0], and Termux's `env` is the
# coreutils multiplexer that dispatches on argv[0]'s basename.
probe="$(mktemp -d)/env"
clang -O2 -DBINARY="\"$PREFIX/bin/env\"" -DTMPDIR_PATH="\"/PROBE_TMPDIR\"" \
  -o "$probe" src/claude-wrapper.c
assert_contains "TMPDIR=/PROBE_TMPDIR"            "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")"
assert_contains "CLAUDE_CODE_TMPDIR=/PROBE_TMPDIR" "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")"
# Must not overwrite a value already in the environment.
assert_contains "TMPDIR=/keep" "$(TMPDIR=/keep "$probe")"

# Conditional update: `claude-code-termux-update` must re-fetch ONLY when the
# resolved version differs from what's installed (so it's safe to schedule).
# Pin to the already-installed version and assert it short-circuits without
# re-downloading.
installed=$(readlink "$PREFIX/opt/claude-code-termux/current")   # claude-<ver>
assert_contains "already current" \
  "$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update 2>&1)"

# Binary cache: when CLAUDE_CODE_CACHE_DIR is set the initial install populated
# it, so a forced re-fetch must reuse the cached bytes ("Using cached") rather
# than re-download — while still re-patching (patchelf + execPath run anyway).
if [ -n "${CLAUDE_CODE_CACHE_DIR:-}" ]; then
  assert_contains "Using cached" \
    "$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update --force 2>&1)"
fi

echo "claude-code-termux test: OK ($VERSION)"
