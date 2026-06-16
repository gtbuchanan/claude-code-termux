#!/data/data/com.termux/files/usr/bin/bash
#
# Runs INSIDE termux/termux-docker:aarch64 (or natively on a Termux device).
# Installs the prebuilt .deb via install.sh (exercising real dependency
# resolution) and tests the behaviors this package fixes — the e2e half of the
# pipeline. The compile half (wrapper + .deb) lives in scripts/compile.sh and
# must run first.
#
#   bash scripts/e2e.sh [version]   # empty → version.sh derives the CalVer
#
set -euxo pipefail

# Resolve paths against the repo root regardless of the caller's cwd: install.sh
# and the prebuilt .deb are looked up relative to it.
cd "$(dirname "$0")/.."

VERSION="${1:-$(bash scripts/version.sh)}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# --- e2e toolchain ----------------------------------------------------------
# The TMPDIR-injection assertion below compiles a tiny variant of the wrapper,
# so the e2e needs clang even though it doesn't assemble the .deb. Install it
# only when absent (a fresh termux-docker has no apt mirror, so pick one first;
# a provisioned device skips straight through).
if ! command -v clang >/dev/null; then
  pkg update
  apt-get install -y clang
fi

# --- Install via the real installer ----------------------------------------
# Reuse install.sh (the single install path) against the .deb that compile.sh
# produced, so CI exercises the actual installer: glibc-repo enablement + apt
# dependency resolution. Settings are merged (not skipped) so we verify them
# below.
shopt -s nullglob
# Absolute path: apt-get install only treats an argument as a local file (not a
# package name) when it's a path it can resolve; a bare relative path fails.
debs=("$PWD"/artifacts/packages/*.deb)
case "${#debs[@]}" in
0)
  echo "error: no .deb in artifacts/packages — run 'mise run compile' first." >&2
  exit 1
  ;;
1) ;;
# artifacts/ persists across runs and compile doesn't purge it, so stale builds
# would make the choice ambiguous — fail rather than guess.
*)
  echo "error: multiple .debs in artifacts/packages; expected one:" >&2
  printf '  %s\n' "${debs[@]}" >&2
  exit 1
  ;;
esac
CLAUDE_CODE_DEB="${debs[0]}" bash install.sh

# --- Layout assertions -----------------------------------------------------
elf_magic() { od -An -tx1 -N4 "$1" | tr -d ' \n'; }

test -x "$PREFIX/bin/claude"
[ "$(elf_magic "$PREFIX/bin/claude")" = "7f454c46" ] ||
  {
    echo "wrapper is not an ELF binary"
    exit 1
  }
test -x "$PREFIX/libexec/claude-code-termux/bootstrap.sh"
test -f "$PREFIX/libexec/claude-code-termux/patch-execpath.py"

# Runtime deps pulled by apt:
command -v jq >/dev/null
command -v python3 >/dev/null
test -x "$PREFIX/glibc/bin/patchelf"

# postinst downloaded + patched the binary:
test -x "$PREFIX/opt/claude-code-termux/current"
[ "$(elf_magic "$PREFIX/opt/claude-code-termux/current")" = "7f454c46" ] ||
  {
    echo "patched binary is not an ELF"
    exit 1
  }

# --- settings.json merge (the shebang fix's mechanism) ---------------------
# postinst writes the LD_PRELOAD re-export — so Claude's subprocesses inherit
# termux-exec and `#!/usr/bin/env …` shebangs resolve — and disables autoUpdates.
settings="${HOME}/.claude/settings.json"
test -f "$settings"
jq -e '.autoUpdates == false' "$settings" >/dev/null
jq -e '.env.LD_PRELOAD | test("libtermux-exec")' "$settings" >/dev/null

# --- Native-path symlink ----------------------------------------------------
# postinst symlinks ~/.local/bin/claude → the launcher so Claude's
# installMethod=native health check passes. It must target the launcher (so the
# env setup is preserved), not the patched binary.
native_link="${HOME}/.local/bin/claude"
test -L "$native_link"
[ "$(readlink "$native_link")" = "$PREFIX/bin/claude" ] ||
  {
    echo "native symlink does not point at the launcher"
    exit 1
  }

# --- Behavior tests (the fixes) --------------------------------------------
assert_contains() { # <needle> <haystack>
  case "$2" in
  *"$1"*) ;;
  *)
    echo "FAIL: expected '$1' in output: $2" >&2
    exit 1
    ;;
  esac
}

# Startup.
claude --version

# grep/find dispatch: Claude routes its embedded tools by argv[0]. The compiled
# wrapper must preserve argv[0] through execv for this to reach ripgrep/bfs —
# the core fix. A bash wrapper would arrive as argv[0]=bash and never dispatch.
assert_contains ripgrep "$( (exec -a rg "$PREFIX/bin/claude" --version) 2>&1 || true)"
assert_contains bfs "$( (exec -a bfs "$PREFIX/bin/claude" --version) 2>&1 || true)"

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
assert_contains "TMPDIR=/PROBE_TMPDIR" "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")"
assert_contains "CLAUDE_CODE_TMPDIR=/PROBE_TMPDIR" "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")"
# Must not overwrite a value already in the environment.
assert_contains "TMPDIR=/keep" "$(TMPDIR=/keep "$probe")"

# Conditional update: `claude-code-termux-update` must re-fetch ONLY when the
# resolved version differs from what's installed (so it's safe to schedule).
# Pin to the already-installed version and assert it short-circuits without
# re-downloading.
installed=$(readlink "$PREFIX/opt/claude-code-termux/current") # claude-<ver>
assert_contains "already current" \
  "$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update 2>&1)"

# Native-symlink self-heal: claude-code-termux-update reconciles
# ~/.local/bin/claude → the launcher (via link-native.sh) before updating, so a
# clobbered symlink recovers without a reinstall. Repoint it elsewhere, run the
# update (pinned to the installed version so it short-circuits the fetch), and
# assert the symlink is restored to the launcher.
ln -sfn /nonexistent "$native_link"
CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update >/dev/null 2>&1
[ "$(readlink "$native_link")" = "$PREFIX/bin/claude" ] ||
  {
    echo "update did not self-heal the native symlink"
    exit 1
  }

# Binary cache: when CLAUDE_CODE_CACHE_DIR is set the initial install populated
# it, so a forced re-fetch must reuse the cached bytes ("Using cached") rather
# than re-download — while still re-patching (patchelf + execPath run anyway).
if [ -n "${CLAUDE_CODE_CACHE_DIR:-}" ]; then
  assert_contains "Using cached" \
    "$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update --force 2>&1)"
fi

# ensure repair: `ensure` must re-patch a present, executable `current` whose ELF
# interpreter was never repointed (a stock/half-patched binary), a state `[ -x ]`
# alone calls healthy. Corrupt the interpreter, run `ensure` pinned to the
# installed version, and assert it is restored. With a warm CLAUDE_CODE_CACHE_DIR
# the repair reuses the cached bytes instead of re-downloading.
patchelf="$PREFIX/glibc/bin/patchelf"
glibc_ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
target=$(readlink -f "$PREFIX/opt/claude-code-termux/current")
LD_PRELOAD='' "$patchelf" --set-interpreter /lib/ld-linux-aarch64.so.1 "$target"
ensure_out=$(CLAUDE_CODE_VERSION="${installed#claude-}" "$PREFIX/libexec/claude-code-termux/bootstrap.sh" ensure 2>&1)
repaired=$(LD_PRELOAD='' "$patchelf" --print-interpreter "$PREFIX/opt/claude-code-termux/current")
[ "$repaired" = "$glibc_ld" ] ||
  {
    echo "ensure did not re-patch the mis-interpreted binary"
    exit 1
  }
if [ -n "${CLAUDE_CODE_CACHE_DIR:-}" ]; then
  assert_contains "Using cached" "$ensure_out"
fi

echo "claude-code-termux test: OK ($VERSION)"
