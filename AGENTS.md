# claude-code-termux — Agent Guide

An aarch64 `.deb` that runs [Claude Code](https://github.com/anthropics/claude-code)
natively on Termux/Android. Anthropic ships Claude Code only as bun-compiled
**glibc** ELF binaries with no android-arm64 build, so `npm i -g
@anthropic-ai/claude-code` is broken on Termux
([claude-code#50270](https://github.com/anthropics/claude-code/issues/50270)).
This package installs a launcher that downloads the official `linux-arm64`
build from Anthropic, patches its ELF interpreter to Termux's glibc loader,
and routes Claude's embedded-tool re-execs back through the launcher.

## Legal / redistribution

This project ships **only its own code**. The Claude Code binary is downloaded
directly from Anthropic at install time and patched locally on-device — it is
**never rehosted** (Anthropic's `LICENSE.md` is "all rights reserved"; their
Commercial Terms bar duplicating/reselling the Services). Never commit or
publish the binary; the `.deb` contains no Anthropic bytes.

## How it works

1. `install.sh` enables the `glibc-repo` apt source and `apt install`s the
   `.deb`; `apt` pulls the runtime deps.
1. `postinst` downloads the `linux-arm64` binary from Anthropic, SHA-256-verifies
   it, runs `patchelf --set-interpreter` to point it at Termux's glibc loader,
   and runs `patch-execpath.py` to blank the subprocess `CLAUDE_CODE_EXECPATH`
   assignment.
1. The compiled C launcher (`bin/claude`) execs the patched binary —
   `execv` **preserves `argv[0]`** (so Claude's embedded `grep`/`find`/`rg`
   dispatch works), it **overwrites `LD_PRELOAD` with the uname shim**
   (`lib/claude-code-termux/uname-spoof.so`): this both evicts termux-exec's
   text-script `libc.so` (which the glibc binary's `ld.so` can't load) and
   preloads a freestanding `uname()` interposer that reports a `< 5.11` kernel,
   so Bun skips the `epoll_pwait2` path that segfaults at startup on newer
   kernels (bun#32489 — see `src/uname-shim.c` and `claude-code#50270`). It also
   **sets `TMPDIR`/`CLAUDE_CODE_TMPDIR`** to the Termux prefix when unset (Termux
   has no writable `/tmp`; see `src/claude-wrapper.c` for the
   env-vs-hardcoded-`/tmp` analysis and the MCP-browser-bridge limitation,
   `claude-code#15637`), and it **sets `DISABLE_AUTOUPDATER`** when unset, a
   second settings-independent layer behind `autoUpdates: false` (next item)
   against the self-updater.
1. `postinst` also merges two keys into `~/.claude/settings.json`:
   `env.LD_PRELOAD` (re-arms termux-exec for subprocess `/usr/bin/env` shebangs)
   and `autoUpdates: false` (so the in-session updater can't clobber the patched
   binary).
1. `postinst` symlinks `~/.local/bin/claude` → the launcher (Anthropic's
   native-install path) so Claude's `installMethod: native` health check passes;
   `postrm` removes it only when it still points at the launcher. The symlink
   targets the launcher (not the patched binary), so the env setup is preserved,
   and `autoUpdates: false` keeps the native self-updater from overwriting it. A
   user-managed regular file at that path is left untouched. The reconcile lives
   in `link-native.sh`, shared by `postinst` and `claude-code-termux-update`, so
   a clobbered symlink self-heals on the next (schedulable) update.

## Layout

| Path | Role |
|---|---|
| `install.sh` | Single install path. Downloads the latest release `.deb` (or installs a local one via `CLAUDE_CODE_DEB=<path>`), enables `glibc-repo`, `apt install`s it. The install flow is in `main` behind a `CLAUDE_CODE_INSTALL_LIB` guard so the unit test can source its pure helpers without running it (and `curl \| bash` still runs `main`). |
| `package/control` | Metadata. `Depends: bash, curl, jq, python3, glibc-runner, patchelf-glibc`. |
| `package/postinst` | Settings merge (skip via `CLAUDE_CODE_SKIP_SETTINGS`) + native-path symlink (via `link-native.sh`) + fetch the binary. |
| `package/postrm` | Removes the fetched binary and the native-path symlink on uninstall. |
| `package/payload/bin/claude-code-termux-update` | Reconcile the native-path symlink (`link-native.sh`), then re-patch only if the version changed (`bootstrap.sh update`; schedulable). `--force` to re-apply. |
| `package/payload/libexec/bootstrap.sh` | Resolve / download (`curl --retry`, optional `CLAUDE_CODE_CACHE_DIR`) / verify / `patchelf` / execPath-patch engine. |
| `package/payload/libexec/link-native.sh` | Idempotent native-path symlink (`~/.local/bin/claude` → launcher) reconcile, shared by `postinst` and the update command. |
| `package/payload/libexec/patch-execpath.py` | The `CLAUDE_CODE_EXECPATH` patch. |
| `package/payload/etc/claude-code-termux.conf` | `CLAUDE_CODE_VERSION` pin + `CLAUDE_CODE_CACHE_DIR` (both empty by default). |
| `src/claude-wrapper.c` | The C launcher (`-DBINARY=`/`-DTMPDIR_PATH=`/`-DUNAME_SHIM=` baked in at compile). `claude_wrapper_run()` takes its exec function as a parameter — a seam the unit tests fake. |
| `src/uname-shim.c` | Freestanding `LD_PRELOAD` `uname()` interposer reporting kernel `5.10.0`, so Bun avoids the `epoll_pwait2` startup segfault (bun#32489). Built by `build-wrapper.sh`, shipped to `lib/claude-code-termux/uname-spoof.so`, preloaded by the launcher. |
| `test/wrapper_test.c` | Unit tests for the launcher (greatest; recording exec stub). |
| `test/install_test.sh` | Hermetic unit tests for `install.sh`'s pure helpers (shUnit2; no network/apt). |
| `test/compat.h` | Test-only `setenv`/`unsetenv` shims for Windows libc; force-included into the test build, never shipped. |
| `vendor/greatest.h` | Vendored single-header test framework (greatest 1.5.0, ISC; from silentbicycle/greatest). |
| `vendor/shunit2` | Vendored single-file shell test framework (shUnit2 2.1.9pre, Apache-2.0; pinned to kward/shunit2 master @ `f39734a` — no tagged release since 2.1.8, and master carries the `egrep`→`grep -E` fix we'd otherwise patch). Drives `scripts/e2e.sh` and `test/install_test.sh`. Carries one local patch (grep `PATCHED FOR TERMUX`; re-apply on bump): `#! /bin/sh` stub scripts → resolve `sh` via PATH (submitted upstream as kward/shunit2#189). |
| `scripts/build-wrapper.sh` | Compile the wrapper + uname shim with Termux's clang. |
| `scripts/build-deb.sh` | Stage + `dpkg-deb --build` → `artifacts/packages/`. |
| `scripts/compile.sh` | Compile the wrapper + assemble the `.deb`, in a Termux env. |
| `scripts/e2e.sh` | Install the prebuilt `.deb` + assert the fixes, in a Termux env. |
| `scripts/docker-run.sh` | Run a termux-side script (`compile.sh`/`e2e.sh`) on your machine via Docker (QEMU off-arm64). |
| `scripts/version.sh` | Prints the version (see Versioning). |
| `hk.pkl` | hk hook definitions (Pkl) — the source of truth for the lint hooks. Imports the shared `@gtbuchanan/hk-config` preset (published GitHub-release Pkl package). |
| `mise.toml` | Host-side dev-tool pins (hk + its linters, zig) + `lockfile = true` + the `hk install --mise` postinstall. |
| `mise.tasks.toml` | Generated by `gtb sync mise` — the `hk:all` / `hk:base` tasks (loaded via `mise.toml`'s `[task_config] includes`). |
| `mise-tasks/` | File-based mise tasks (`mise tasks ls`; see Dev environment). |

## Dev environment (mise)

[mise](https://mise.jdx.dev) pins the host-side dev tooling and runs the dev
tasks. `mise.lock` (`lockfile = true`) records checksum-verified URLs for all
common platforms so installs are reproducible across the Windows/arm64 dev
hosts and the Linux CI runner.

- `mise install` — install the pinned tools; the `hk install --mise`
  postinstall wires up hk's Git hooks. Run once after cloning.
- `mise run hk:all` — run the hk hooks over all files (autofixes locally,
  checks in CI). `mise run hk:base [ref]` runs them over files changed from a
  base ref (default `origin/main`). Append `-- -S <step>` to target one step.
- `mise run test:fast` — the fast, host-native unit suites (no Termux/Docker,
  milliseconds); an aggregator over two focused tasks you can also run alone:
  - `mise run test:greatest` — the C launcher: compiles `src/claude-wrapper.c`
    with mise's `zig` and runs it directly. Append `-- -v` for per-test greatest
    output.
  - `mise run test:shunit2` — `install.sh`'s pure helpers, via shUnit2.
- `mise run check` — the fast local gate: the hk hooks (`hk:all`) plus
  the unit suites (`test:fast`). No Docker.
- `mise run compile [version]` — compile the launcher + assemble the `.deb`
  (→ `artifacts/packages/`), env-aware: `scripts/compile.sh` natively on a Termux
  device, else `scripts/docker-run.sh` (the container) on a dev host.
- `mise run test:e2e [version]` — install the prebuilt `.deb` and assert the
  fixes; requires a prior `mise run compile`. Same Termux-or-Docker envelope as
  `compile`.
- `mise run build` — run everything: `check`, `compile`, then `test:e2e` (which
  `wait_for`s `compile`, so it lands against a fresh `.deb`). The canonical
  pre-PR pipeline. See Building & packaging.

CI runs the hooks through the shared
`gtbuchanan/tooling/.github/workflows/pre-commit.yml` reusable workflow (which
installs the pinned tools via the `mise-setup` action — `MISE_LOCKED=1`,
lockfile-keyed cache — and runs `mise run hk:base` against the PR diff). The
local `mise run hk:all` runs the same hooks over all tracked files.

## Versioning

CalVer `YYYY.M.<counter>` via `scripts/version.sh`, where `<counter>` is
`GITHUB_RUN_NUMBER` (unique + monotonic) or `0` locally. No manual version file.
Unpadded month (leading zeros read oddly / break some parsers).

## Building & packaging

Hand-assembled and **must run inside `termux/termux-docker:aarch64`** (needs
Termux's clang + bionic for the wrapper; runs natively on arm64 hosts, under
QEMU on x86 dev hosts): `build-wrapper.sh` compiles the
launcher → `build-deb.sh` stages the payload under the Termux prefix and runs
`dpkg-deb --build`. Output goes to `artifacts/{build,packages}` (git-ignored).
The version is passed in by the caller; `build-deb.sh`, `compile.sh`, and
`e2e.sh` default to `scripts/version.sh`.

## Testing locally

Two layers. Fast **unit tests** for the launcher's logic (env shaping + the exec
handoff) and for `install.sh`'s pure helpers run anywhere via `mise run
test:fast` — no Termux, no Docker (see Dev environment). The end-to-end
behaviors (real binary, dispatch, install) need the container, split across two
tasks:

`mise run compile` produces the `.deb`, then `mise run test:e2e` installs it via
`install.sh` and asserts the real fixes: `argv[0]=rg`/`bfs` dispatch to the
embedded ripgrep/bfs, startup with `LD_PRELOAD` set (the launcher overwrites it
with the uname shim), a runtime-init boot guard (`claude mcp list` spins up
Bun's event loop — catching startup crashes the `--version` fast path can't,
e.g. the Bun 1.4.0 `epoll_pwait2` segfault the uname shim prevents), `TMPDIR`
injection, the `settings.json` merge, the conditional/cached update paths, and
the interpreter-repair `ensure`. The suite is built on the vendored shUnit2 (a
single sourced file; the install is its `oneTimeSetUp`, behaviors are
definition-ordered `test_*` functions with the state-mutating ones last). On a
dev host both tasks dispatch to `scripts/docker-run.sh <script>`, which pulls
`termux/termux-docker:aarch64` and runs the script in it — natively on arm64
hosts, under QEMU elsewhere (needs Docker + `binfmt`). It bind-mounts
`artifacts/` writable over the read-only source, so the `.deb` `compile`
produces is visible to a later `test:e2e`.

For local speed, `docker-run.sh` also mounts gitignored host caches under
`artifacts/cache/` — the Termux **apt archive** cache (so build/runtime `.deb`s
aren't re-downloaded; apt still fully installs + resolves) and a **`claude`**
binary cache via `CLAUDE_CODE_CACHE_DIR` (raw pre-patch bytes; `patchelf` + the
execPath patch still run). In CI the cache dirs start empty per checkout, so the
cache-hit path is still exercised within a run without persisting across runs.

**termux-docker gotcha:** its entrypoint drops privileges and **sanitizes the
environment**, so `docker run -e VAR=…` does **not** reach the command — set env
vars **inline** in the `bash -c` string instead.

## CI/CD

- **`ci.yml`** (`pull_request` + `workflow_call`): a `pre-commit` job that calls
  the shared `tooling/.github/workflows/pre-commit.yml` reusable (PR-only — the
  reusable diffs against the PR base, so it's skipped on push/schedule
  `workflow_call` invocations); a `unit` job that runs `mise run test:fast`
  (the launcher tests build + run natively via `zig`, the `install.sh` tests via
  shUnit2 — no container, fast, arch-independent); plus the `compile` and `e2e`
  jobs. `compile` runs `mise run
  compile` and uploads the `.deb` as an artifact; `e2e` (`needs: compile`)
  downloads it and runs `mise run test:e2e` — so a compile break and an
  install/behavior break surface as distinct job failures. Both go through the
  same mise tasks (→ `scripts/docker-run.sh`) a dev host uses, so the container
  plumbing lives in one place. They run on a **native arm64** runner
  (`ubuntu-24.04-arm`) — no QEMU, so the aarch64 container runs natively. The
  `workflow_call` `claude_version` input (empty = latest) pins which Claude
  Code version `e2e` installs.
- **`release-watch.yml`** (`schedule: daily` + `workflow_dispatch`): polls
  Anthropic's release channel (the endpoint `bootstrap.sh` resolves against),
  and on a **new** version — gated by an `actions/cache` key per version so it
  runs once per release — calls `ci.yml` pinned to that version. The cache is
  saved only on success (a break is retried daily); a failure opens a
  deduplicated issue. This catches `patch-execpath.py` anchor breaks (bun
  minifier identifier rotation) within a day of release.
- **`cd.yml`** (`push: main`): reuses `ci.yml`, then a `release` job **gated by
  the `release` GitHub Environment** (configure required reviewers in repo
  settings for the gate to pause) downloads the built artifact and publishes a
  GitHub release. It does **not** rebuild — it ships the exact bytes that were
  tested; the version is read from the `.deb` filename.

## Conventions

- Scripts that run inside termux-docker use the absolute Termux bash shebang
  (`#!/data/data/com.termux/files/usr/bin/bash`); dev-host scripts use
  `#!/usr/bin/env bash`.
- Releases are CalVer and cut by approving the `release` environment gate on a
  push to `main`; there is no version file to bump.
