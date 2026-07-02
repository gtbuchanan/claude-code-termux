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
# Built on the vendored shUnit2 (vendor/shunit2): oneTimeSetUp performs the
# one-shot install + probe compile, then each behavior is a `test_*` function
# run in definition order — so the state-mutating checks (self-heal, --force,
# ensure-repair) come last. shUnit2 owns pass/fail and prints the summary, so
# this script deliberately does NOT `set -e` (errexit fights the framework);
# preconditions in oneTimeSetUp fail-fast explicitly via `fatal` instead.

# Resolve paths against the repo root regardless of the caller's cwd: install.sh,
# the prebuilt .deb, the wrapper source, and vendor/shunit2 are all looked up
# relative to it.
cd "$(dirname "$0")/.." || exit 1

VERSION="${1:-$(bash scripts/version.sh)}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

settings="${HOME}/.claude/settings.json"
native_link="${HOME}/.local/bin/claude"
preload_lib="$PREFIX/lib/libtermux-exec-ld-preload.so"
patchelf="$PREFIX/glibc/bin/patchelf"
glibc_ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
# Populated by oneTimeSetUp, read by the tests.
installed=""
probe=""

elf_magic() { od -An -tx1 -N4 "$1" | tr -d ' \n'; }
fatal() {
  echo "error: $*" >&2
  exit 1
}

oneTimeSetUp() {
  echo "==> e2e setup for ${VERSION} (install + probe compile)" >&2

  # The TMPDIR-injection test compiles a tiny wrapper variant, so the e2e needs
  # clang even though it doesn't assemble the .deb. Install only when absent (a
  # fresh termux-docker has no apt mirror, so pick one first; a provisioned
  # device skips straight through).
  if ! command -v clang >/dev/null; then
    pkg update >&2 || fatal "pkg update failed"
    apt-get install -y clang >&2 || fatal "clang install failed"
  fi

  # Install via install.sh (the single install path) against the .deb compile.sh
  # produced, so we exercise the real installer: glibc-repo enablement + apt
  # dependency resolution. Settings are merged (not skipped) so we verify them.
  # nullglob so an empty packages dir yields an empty array, not a literal
  # `*.deb`. Scoped tight and unset right after: left on, it breaks shUnit2's
  # unquoted `${_SHUNIT_LINENO_}` expansion (the `[...]` glob chars in the macro
  # get eaten) and spams "unexpected EOF" on every assert. Absolute path:
  # apt-get treats an argument as a local file only when it's a resolvable
  # path; a bare relative path is read as a package name.
  local debs
  shopt -s nullglob
  debs=("$PWD"/artifacts/packages/*.deb)
  shopt -u nullglob
  case "${#debs[@]}" in
  0) fatal "no .deb in artifacts/packages — run 'mise run compile' first." ;;
  1) ;;
  # artifacts/ persists across runs and compile doesn't purge it, so stale builds
  # make the choice ambiguous — fail rather than guess.
  *)
    printf '  %s\n' "${debs[@]}" >&2
    fatal "multiple .debs in artifacts/packages; expected one (see above)."
    ;;
  esac
  # Seed a pre-existing user key so the suite verifies postinst *merges* into
  # settings.json rather than overwriting it (the keys it writes would pass
  # either way; only a survivor proves the merge).
  mkdir -p "$(dirname "$settings")"
  printf '{"permissions":{"allow":["Bash(echo:*)"]}}\n' >"$settings"
  CLAUDE_CODE_DEB="${debs[0]}" bash install.sh >&2 || fatal "install.sh failed"

  # claude-<ver>; errexit is off, so guard against a missing/unreadable symlink
  # rather than letting the update/ensure tests run with an empty version pin.
  installed=$(readlink "$PREFIX/opt/claude-code-termux/current") ||
    fatal "current symlink missing or unreadable after install"
  [ -n "$installed" ] || fatal "current symlink resolved to an empty version"

  # Probe whose BINARY is `env`, so the TMPDIR tests can read the environment the
  # wrapper hands to the exec'd process. It must be named `env`: the wrapper
  # preserves argv[0], and Termux's `env` is the coreutils multiplexer that
  # dispatches on argv[0]'s basename. UNAME_SHIM points at the installed shim
  # (already staged by the install above) — the wrapper LD_PRELOADs it, and
  # bionic's linker aborts on a missing preload.
  probe="$(mktemp -d)/env"
  clang -O2 -DBINARY="\"$PREFIX/bin/env\"" -DTMPDIR_PATH="\"/PROBE_TMPDIR\"" \
    -DUNAME_SHIM="\"$PREFIX/lib/claude-code-termux/uname-spoof.so\"" \
    -DRESOLV_SHIM="\"$PREFIX/lib/claude-code-termux/resolv-redirect.so\"" \
    -o "$probe" src/claude-wrapper.c >&2 || fatal "probe compile failed"
}

# --- Layout -----------------------------------------------------------------
test_wrapper_installed() {
  assertTrue 'wrapper installed + executable' "[ -x '$PREFIX/bin/claude' ]"
}
test_wrapper_is_elf() {
  assertEquals 'wrapper is an ELF binary' \
    7f454c46 "$(elf_magic "$PREFIX/bin/claude")"
}
test_resolv_shim_installed() {
  assertTrue 'resolv-redirect.so installed' \
    "[ -f '$PREFIX/lib/claude-code-termux/resolv-redirect.so' ]"
}
test_resolv_shim_is_elf() {
  assertEquals 'resolv-redirect.so is an ELF' \
    7f454c46 "$(elf_magic "$PREFIX/lib/claude-code-termux/resolv-redirect.so")"
}
# The crux of #25: the shim must carry no DT_NEEDED (a libdl.so dep would break
# the glibc ld.so load; see src/resolv-shim.c). The startup tests catch this
# end-to-end too, but this pinpoints a regression to the shim.
test_resolv_shim_has_no_dt_needed() {
  local needed rc
  # No 2>/dev/null: a patchelf failure must surface, not be swallowed into an
  # empty (assertNull-passing) result. Assert it ran before trusting the output.
  needed=$(LD_PRELOAD='' "$patchelf" --print-needed \
    "$PREFIX/lib/claude-code-termux/resolv-redirect.so")
  rc=$?
  assertEquals 'patchelf --print-needed ran' 0 "$rc"
  assertNull 'resolv-redirect.so has no DT_NEEDED (no libdl.so)' "$needed"
}
test_bootstrap_installed() {
  assertTrue 'bootstrap.sh installed + executable' \
    "[ -x '$PREFIX/libexec/claude-code-termux/bootstrap.sh' ]"
}
test_patch_execpath_installed() {
  assertTrue 'patch-execpath.py installed' \
    "[ -f '$PREFIX/libexec/claude-code-termux/patch-execpath.py' ]"
}
test_runtime_deps_installed() {
  assertTrue 'jq on PATH' 'command -v jq >/dev/null'
  assertTrue 'python3 on PATH' 'command -v python3 >/dev/null'
  assertTrue 'patchelf installed' "[ -x '$patchelf' ]"
}
test_patched_binary_present() {
  assertTrue 'patched binary present + executable' \
    "[ -x '$PREFIX/opt/claude-code-termux/current' ]"
}
test_patched_binary_is_elf() {
  assertEquals 'patched binary is an ELF' \
    7f454c46 "$(elf_magic "$PREFIX/opt/claude-code-termux/current")"
}

# --- settings.json merge (the shebang fix's mechanism) ----------------------
# postinst writes the LD_PRELOAD re-export — so Claude's subprocesses inherit
# termux-exec and `#!/usr/bin/env …` shebangs resolve — and disables autoUpdates.
test_settings_exists() {
  assertTrue 'settings.json exists' "[ -f '$settings' ]"
}
test_settings_autoupdates_disabled() {
  assertTrue 'autoUpdates disabled' \
    "jq -e '.autoUpdates == false' '$settings' >/dev/null"
}
test_settings_ld_preload_present() {
  assertTrue 'LD_PRELOAD re-export present' \
    "jq -e '.env.LD_PRELOAD | test(\"libtermux-exec\")' '$settings' >/dev/null"
}
test_settings_preserves_existing_keys() {
  assertTrue 'settings.json merge preserves pre-existing keys' \
    "jq -e '.permissions.allow | index(\"Bash(echo:*)\")' '$settings' >/dev/null"
}

# postinst resolves the termux-exec preload lib by name, since it varies across
# termux-exec versions (libtermux-exec-ld-preload.so on 2.x, only the legacy
# libtermux-exec.so on 1.x). The install above already covered the modern name;
# these drive postinst in an isolated PREFIX/HOME — with the post-merge steps
# (link-native, bootstrap ensure) stubbed out — so only the settings merge runs,
# exercising the fallback and the no-lib branch without network or real state.
_run_isolated_postinst() { # $1 = fake root; caller pre-creates $1/lib/*
  local root="$1"
  mkdir -p "$root/libexec/claude-code-termux" "$root/home"
  printf '#!%s\nexit 0\n' "$PREFIX/bin/bash" \
    >"$root/libexec/claude-code-termux/link-native.sh"
  printf '#!%s\nexit 0\n' "$PREFIX/bin/bash" \
    >"$root/libexec/claude-code-termux/bootstrap.sh"
  chmod +x "$root/libexec/claude-code-termux/"*.sh
  PREFIX="$root" HOME="$root/home" bash "$PWD/package/postinst" configure 2>/dev/null
}
test_postinst_falls_back_to_legacy_preload_lib() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/lib"
  : >"$root/lib/libtermux-exec.so" # only the legacy name present
  _run_isolated_postinst "$root"
  assertEquals 'falls back to legacy libtermux-exec.so when modern name absent' \
    "$root/lib/libtermux-exec.so" \
    "$(jq -r '.env.LD_PRELOAD' "$root/home/.claude/settings.json")"
  rm -rf "$root"
}
test_postinst_skips_preload_when_no_lib() {
  local root s
  root=$(mktemp -d)
  mkdir -p "$root/lib" # no preload lib at all
  _run_isolated_postinst "$root"
  s="$root/home/.claude/settings.json"
  assertEquals 'no LD_PRELOAD written when no termux-exec lib found' false \
    "$(jq -c '(.env // {}) | has("LD_PRELOAD")' "$s")"
  assertTrue 'autoUpdates still disabled when no lib found' \
    "jq -e '.autoUpdates == false' '$s' >/dev/null"
  rm -rf "$root"
}
test_postinst_clears_stale_preload_when_no_lib() {
  local root s
  root=$(mktemp -d)
  mkdir -p "$root/lib" "$root/home/.claude" # no preload lib present
  # A prior install left a now-missing preload path; with no lib found the merge
  # must clear it, not leave subprocess exec armed with a missing library.
  printf '{"env":{"FOO":"bar","LD_PRELOAD":"/gone/libtermux-exec-ld-preload.so"}}\n' \
    >"$root/home/.claude/settings.json"
  _run_isolated_postinst "$root"
  s="$root/home/.claude/settings.json"
  assertEquals 'stale LD_PRELOAD removed when no lib found' false \
    "$(jq -c '.env | has("LD_PRELOAD")' "$s")"
  assertEquals 'unrelated env keys preserved' bar "$(jq -r '.env.FOO' "$s")"
  rm -rf "$root"
}

# --- Native-path symlink ----------------------------------------------------
# postinst symlinks ~/.local/bin/claude → the launcher (not the patched binary)
# so Claude's installMethod=native health check passes with the env setup intact.
test_native_path_is_symlink() {
  assertTrue 'native path is a symlink' "[ -L '$native_link' ]"
}
test_native_symlink_targets_launcher() {
  assertEquals 'native symlink → launcher' \
    "$PREFIX/bin/claude" "$(readlink "$native_link")"
}

# --- Behavior (the fixes) ---------------------------------------------------
test_startup() {
  assertTrue 'startup: claude --version' \
    "'$PREFIX/bin/claude' --version >/dev/null 2>&1"
}

# Runtime-init crash guard. `--version`/`--help` are fast paths that exit before
# Bun spins up its event loop, so they stay green even when the bundled runtime
# can't boot on this kernel — exactly how Claude 2.1.181's Bun 1.4.0 bump
# (epoll_pwait2 with no ENOSYS fallback, bun#32489) slipped past CI as a
# segfault-at-startup ("Bun has crashed") for every real session while
# `claude --version` kept exiting 0. `mcp list` boots the full runtime (event
# loop + HTTP thread) and exits cleanly with no servers configured — no network
# or API auth — so a future runtime that can't start on Termux fails the build
# instead of shipping. See anthropics/claude-code#50270.
test_startup_boots_runtime() {
  local out
  out=$("$PREFIX/bin/claude" mcp list 2>&1)
  assertEquals 'mcp list boots the runtime and exits 0' 0 "$?"
  assertNotContains 'runtime boots without a Bun crash' "$out" 'Bun has crashed'
}

# grep/find dispatch: Claude routes its embedded tools by argv[0]. The compiled
# wrapper must preserve argv[0] through execv to reach ripgrep/bfs — the core
# fix. A bash wrapper would arrive as argv[0]=bash and never dispatch.
test_argv0_rg_dispatches_to_ripgrep() {
  local out
  out=$( (exec -a rg "$PREFIX/bin/claude" --version) 2>&1)
  assertEquals 'argv[0]=rg exits successfully' 0 "$?"
  assertContains 'argv[0]=rg dispatches to ripgrep' "$out" ripgrep
}
test_argv0_bfs_dispatches_to_bfs() {
  local out
  out=$( (exec -a bfs "$PREFIX/bin/claude" --version) 2>&1)
  assertEquals 'argv[0]=bfs exits successfully' 0 "$?"
  assertContains 'argv[0]=bfs dispatches to bfs' "$out" bfs
}

# LD_PRELOAD clearing: termux-exec is preloaded into every Termux shell. The
# wrapper must unset it before exec'ing the glibc binary, or ld.so crashes on
# termux-exec's text-script libc.so. A clean startup with it preloaded proves it.
test_preload_lib_present() {
  assertTrue 'termux-exec preload lib present' "[ -e '$preload_lib' ]"
}
test_startup_with_ld_preload_set() {
  assertTrue 'startup with LD_PRELOAD set' \
    "LD_PRELOAD='$preload_lib' '$PREFIX/bin/claude' --version >/dev/null 2>&1"
}

# resolv redirect: compile a shim variant with temp sentinels (the probe
# pattern) + a tiny opener, then prove fopen(SRC) is rewritten to DST (SRC
# absent, so an unredirected open misses). Exercises src/resolv-shim.c directly,
# independent of a c-ares-affected Claude version. See #25.
test_resolv_redirect_rewrites_configured_path() {
  local dir src dst rc
  dir=$(mktemp -d)
  src="$dir/sys-resolv.conf" # stands in for the absolute /etc/resolv.conf
  dst="$dir/prefix-resolv.conf"
  printf 'nameserver 203.0.113.1\n' >"$dst" # marker; src intentionally absent
  clang -O2 -Wall -Wextra -Werror -shared -fPIC -nostdlib -ffreestanding \
    -fno-stack-protector -fno-builtin \
    -DRESOLV_SRC="\"$src\"" -DRESOLV_DST="\"$dst\"" \
    -o "$dir/resolv-redirect.so" src/resolv-shim.c 2>"$dir/cc.log"
  rc=$?
  assertEquals "resolv shim test build ($(cat "$dir/cc.log"))" 0 "$rc"
  cat >"$dir/opener.c" <<'EOF'
#include <stdio.h>
int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "r");
  if (!f) { puts("MISS"); return 1; }
  char b[64];
  if (!fgets(b, sizeof b, f)) b[0] = '\0';
  fputs(b, stdout);
  fclose(f);
  return 0;
}
EOF
  clang -O2 -o "$dir/opener" "$dir/opener.c" 2>/dev/null
  assertEquals 'opener test build' 0 $?
  assertEquals 'absent source path misses without the shim' \
    MISS "$("$dir/opener" "$src" 2>&1)"
  assertContains 'shim redirects fopen(SRC) to the configured target' \
    "$(LD_PRELOAD="$dir/resolv-redirect.so" "$dir/opener" "$src" 2>&1)" '203.0.113.1'
  rm -rf "$dir"
}

# TMPDIR injection: Termux has no writable /tmp, so the wrapper sets TMPDIR +
# CLAUDE_CODE_TMPDIR (only when unset). The probe (BINARY=env) prints the env the
# wrapper hands to the exec'd process.
test_tmpdir_injected_when_unset() {
  assertContains 'TMPDIR injected when unset' \
    "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")" 'TMPDIR=/PROBE_TMPDIR'
}
test_claude_code_tmpdir_injected_when_unset() {
  assertContains 'CLAUDE_CODE_TMPDIR injected when unset' \
    "$(env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$probe")" 'CLAUDE_CODE_TMPDIR=/PROBE_TMPDIR'
}
test_tmpdir_preserved_when_set() {
  assertContains 'TMPDIR preserved when already set' \
    "$(TMPDIR=/keep "$probe")" 'TMPDIR=/keep'
}
test_claude_code_tmpdir_preserved_when_set() {
  assertContains 'CLAUDE_CODE_TMPDIR preserved when already set' \
    "$(CLAUDE_CODE_TMPDIR=/keep-cc "$probe")" 'CLAUDE_CODE_TMPDIR=/keep-cc'
}

# Conditional update: claude-code-termux-update must re-fetch ONLY when the
# resolved version differs from what's installed (so it's safe to schedule).
test_update_short_circuits_on_same_version() {
  local out
  out=$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update 2>&1)
  assertEquals 'update short-circuit exits successfully' 0 "$?"
  assertContains 'update short-circuits on same version' "$out" 'already current'
}

# Preflight: when the device can't exec a patched-interpreter glibc binary, the
# fetch must abort with a clear message BEFORE the multi-MB download rather than
# failing mid-patch. Drive bootstrap against a stub patchelf that emits the
# kernel's rejection signature, in an isolated PREFIX/GLIBC_PREFIX so no real
# state or network is touched (version pinned → no release lookup; the abort
# lands before any download).
test_preflight_aborts_when_glibc_exec_fails() {
  local fake out
  fake=$(mktemp -d)
  mkdir -p "$fake/glibc/bin" "$fake/glibc/lib" "$fake/opt/claude-code-termux"
  cat >"$fake/glibc/bin/patchelf" <<EOF
#!$PREFIX/bin/bash
echo 'CANNOT LINK EXECUTABLE "x": library "libstdc++.so.6" not found' >&2
exit 1
EOF
  chmod +x "$fake/glibc/bin/patchelf"
  : >"$fake/glibc/lib/ld-linux-aarch64.so.1"
  # Resolve the (installed) bootstrap path up front: the inline assignments below
  # set the child's environment, so referencing $PREFIX in the same command would
  # see the real prefix, not $fake (and shellcheck SC2097/SC2098 would flag it).
  local boot="$PREFIX/libexec/claude-code-termux/bootstrap.sh"
  out=$(PREFIX="$fake" GLIBC_PREFIX="$fake/glibc" CLAUDE_CODE_VERSION=9.9.9 \
    "$boot" --force 2>&1)
  assertNotEquals 'preflight aborts with non-zero status' 0 "$?"
  assertContains 'preflight surfaces the cannot-run message' \
    "$out" "can't run on this device"
  assertNotContains 'preflight aborts before downloading' "$out" 'Downloading'
  rm -rf "$fake"
}

# --- State-mutating checks (kept last; order matters) -----------------------
# Self-heal: the update reconciles ~/.local/bin/claude → the launcher (via
# link-native.sh) before updating, so a clobbered symlink recovers without a
# reinstall. Pinned to the installed version so it short-circuits the fetch.
test_update_self_heals_native_symlink() {
  ln -sfn /nonexistent "$native_link"
  CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update >/dev/null 2>&1
  assertEquals 'update self-heals the native symlink' \
    "$PREFIX/bin/claude" "$(readlink "$native_link")"
}

# Binary cache: when CLAUDE_CODE_CACHE_DIR is set the initial install populated
# it, so a forced re-fetch reuses the cached bytes ("Using cached") rather than
# re-download — while still re-patching. Skipped (the --force is not even run)
# when no cache dir is configured, e.g. a bare local invocation.
test_forced_refetch_reuses_cache() {
  if [ -z "${CLAUDE_CODE_CACHE_DIR:-}" ]; then
    echo "skip: CLAUDE_CODE_CACHE_DIR unset — not exercising the cache path" >&2
    return 0
  fi
  local out
  out=$(CLAUDE_CODE_VERSION="${installed#claude-}" claude-code-termux-update --force 2>&1)
  assertEquals 'forced re-fetch exits successfully' 0 "$?"
  assertContains 'forced re-fetch reuses the binary cache' "$out" 'Using cached'
}

# ensure repair: ensure must re-patch a present, executable `current` whose ELF
# interpreter was never repointed (a stock/half-patched binary) — a state `[ -x ]`
# alone calls healthy. Corrupt the interpreter, run ensure pinned to the installed
# version, and assert it is restored (reusing the cache when one is configured).
test_ensure_repairs_mis_interpreted_binary() {
  local target out
  target=$(readlink -f "$PREFIX/opt/claude-code-termux/current")
  LD_PRELOAD='' "$patchelf" --set-interpreter /lib/ld-linux-aarch64.so.1 "$target"
  # Guard the setup: if the corruption silently failed, ensure would see a
  # healthy binary and the test would pass without exercising the repair.
  assertEquals 'setup: interpreter corrupted before ensure' /lib/ld-linux-aarch64.so.1 \
    "$(LD_PRELOAD='' "$patchelf" --print-interpreter "$target")"
  out=$(CLAUDE_CODE_VERSION="${installed#claude-}" \
    "$PREFIX/libexec/claude-code-termux/bootstrap.sh" ensure 2>&1)
  assertEquals 'ensure exits successfully' 0 "$?"
  assertEquals 'ensure re-patches a mis-interpreted binary' "$glibc_ld" \
    "$(LD_PRELOAD='' "$patchelf" --print-interpreter "$PREFIX/opt/claude-code-termux/current")"
  if [ -n "${CLAUDE_CODE_CACHE_DIR:-}" ]; then
    assertContains 'ensure repair reuses the binary cache' "$out" 'Using cached'
  fi
}

# shUnit2 parses "$@" for test-name filters; clear the forwarded version arg so
# it runs the whole suite, then hand control to the framework (which discovers
# the test_* functions above and prints the run summary).
set --
# shellcheck source=/dev/null
. ./vendor/shunit2
