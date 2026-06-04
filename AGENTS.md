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
   dispatch works), it **clears `LD_PRELOAD`** (so the glibc binary's `ld.so`
   doesn't choke on termux-exec's text-script `libc.so`), and it **sets
   `TMPDIR`/`CLAUDE_CODE_TMPDIR`** to the Termux prefix when unset (Termux has no
   writable `/tmp`; see `src/claude-wrapper.c` for the env-vs-hardcoded-`/tmp`
   analysis and the MCP-browser-bridge limitation, `claude-code#15637`).
1. `postinst` also merges two keys into `~/.claude/settings.json`:
   `env.LD_PRELOAD` (re-arms termux-exec for subprocess `/usr/bin/env` shebangs)
   and `autoUpdates: false` (so the in-session updater can't clobber the patched
   binary).
1. `postinst` symlinks `~/.local/bin/claude` → the launcher (Anthropic's
   native-install path) so Claude's `installMethod: native` health check passes;
   `postrm` removes it only when it still points at the launcher. The symlink
   targets the launcher (not the patched binary), so the env setup is preserved,
   and `autoUpdates: false` keeps the native self-updater from overwriting it. A
   user-managed regular file at that path is left untouched.

## Layout

| Path | Role |
|---|---|
| `install.sh` | Single install path. Downloads the latest release `.deb` (or installs a local one via `CLAUDE_CODE_DEB=<path>`), enables `glibc-repo`, `apt install`s it. |
| `package/control` | Metadata. `Depends: bash, curl, jq, python3, glibc-runner, patchelf-glibc`. |
| `package/postinst` | Settings merge (skip via `CLAUDE_CODE_SKIP_SETTINGS`) + native-path symlink (`~/.local/bin/claude`) + fetch the binary. |
| `package/postrm` | Removes the fetched binary and the native-path symlink on uninstall. |
| `package/payload/bin/claude-code-termux-update` | Re-patch only if the version changed (`bootstrap.sh update`; schedulable). `--force` to re-apply. |
| `package/payload/libexec/bootstrap.sh` | Resolve / download (`curl --retry`, optional `CLAUDE_CODE_CACHE_DIR`) / verify / `patchelf` / execPath-patch engine. |
| `package/payload/libexec/patch-execpath.py` | The `CLAUDE_CODE_EXECPATH` patch. |
| `package/payload/etc/claude-code-termux.conf` | `CLAUDE_CODE_VERSION` pin + `CLAUDE_CODE_CACHE_DIR` (both empty by default). |
| `src/claude-wrapper.c` | The C launcher (`-DBINARY=` baked in at compile). |
| `scripts/build-wrapper.sh` | Compile the wrapper with Termux's clang. |
| `scripts/build-deb.sh` | Stage + `dpkg-deb --build` → `artifacts/packages/`. |
| `scripts/test.sh` | Build + install + assert the fixes, inside termux-docker. |
| `scripts/test-docker.sh` | Run `test.sh` on your machine via Docker (QEMU off-arm64). |
| `scripts/version.sh` | Prints the version (see Versioning). |
| `mise.toml` | Host-side dev-tool pins + `lockfile = true`. Tasks live in `mise-tasks/`. |
| `.pre-commit-config.yaml` | prek hook definitions — the source of truth for the lint hooks. |
| `mise-tasks/` | File-based mise tasks (`mise tasks ls`; see Dev environment). |

## Dev environment (mise)

[mise](https://mise.jdx.dev) pins the host-side dev tooling and runs the dev
tasks. `mise.lock` (`lockfile = true`) records checksum-verified URLs for all
common platforms so installs are reproducible across the Windows/arm64 dev
hosts and the Linux CI runner.

- `mise run bootstrap` — install the prek git hooks (run once after cloning).
- `mise run pre-commit:{staged,pr,all}` — run the prek hooks (see
  `.pre-commit-config.yaml`) scoped to staged changes, this branch vs
  `origin/main`, or all files. Append `-- <hook-id>` to target one hook.
- `mise run build [version]` — the full pipeline (compile + package + install +
  assert), env-aware: `scripts/test.sh` natively on a Termux device, else
  `scripts/test-docker.sh` (the container) on a dev host. See Building & packaging.

CI runs the hooks through the shared
`gtbuchanan/tooling/.github/workflows/pre-commit.yml` reusable workflow (which
installs the pinned tools via the `mise-setup` action — `MISE_LOCKED=1`,
lockfile-keyed cache — and runs prek against the PR diff). The local task runs
the same hooks over all tracked files.

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
The version is passed in by the caller; `build-deb.sh`/`test.sh` default to
`scripts/version.sh`.

## Testing locally

`scripts/test-docker.sh [version]` pulls `termux/termux-docker:aarch64` and runs
`scripts/test.sh` in it — natively on arm64 hosts, under QEMU elsewhere (needs
Docker + `binfmt`). `test.sh` builds the
`.deb`, installs it via `install.sh`, and asserts the real fixes: `argv[0]=rg`/
`bfs` dispatch to the embedded ripgrep/bfs, `LD_PRELOAD`-cleared startup,
`TMPDIR` injection, the `settings.json` merge, and the conditional/cached update
paths.

For local speed, `test-docker.sh` mounts gitignored host caches under
`artifacts/cache/` — the Termux **apt archive** cache (so build/runtime `.deb`s
aren't re-downloaded; apt still fully installs + resolves) and a **`claude`**
binary cache via `CLAUDE_CODE_CACHE_DIR` (raw pre-patch bytes; `patchelf` + the
execPath patch still run). CI skips the caches (native arm64 + fast link) but
sets an ephemeral `CLAUDE_CODE_CACHE_DIR` so the cache-hit path is still tested.

**termux-docker gotcha:** its entrypoint drops privileges and **sanitizes the
environment**, so `docker run -e VAR=…` does **not** reach the command — set env
vars **inline** in the `bash -c` string instead.

## CI/CD

- **`ci.yml`** (`pull_request` + `workflow_call`): a `pre-commit` job that calls
  the shared `tooling/.github/workflows/pre-commit.yml` reusable (PR-only — the
  reusable diffs against the PR base, so it's skipped on push/schedule
  `workflow_call` invocations) plus the termux build/test job, which builds +
  installs + tests the `.deb` once and uploads it as an artifact. Runs on a
  **native arm64** runner
  (`ubuntu-24.04-arm`) — no QEMU, so the aarch64 container runs natively. The
  `workflow_call` `claude_version` input (empty = latest) pins which Claude
  Code version the test installs.
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
  tested; the version is read from the `.deb` filename. A peer `pre-commit` job
  calls the shared `tooling/.github/workflows/pre-commit-seed.yml` reusable to
  warm the prek hook-environment cache on `main` so PR builds restore it.

## Conventions

- Scripts that run inside termux-docker use the absolute Termux bash shebang
  (`#!/data/data/com.termux/files/usr/bin/bash`); dev-host scripts use
  `#!/usr/bin/env bash`.
- Releases are CalVer and cut by approving the `release` environment gate on a
  push to `main`; there is no version file to bump.
