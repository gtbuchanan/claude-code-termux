# claude-code-termux

Run [Claude Code](https://github.com/anthropics/claude-code) natively on
Termux/Android (aarch64).

Anthropic ships Claude Code only as bun-compiled **glibc** ELF binaries — there
is no android-arm64 build — so `npm i -g @anthropic-ai/claude-code` is broken on
Termux ([claude-code#50270](https://github.com/anthropics/claude-code/issues/50270)).
This package installs a small compiled launcher that downloads the official
`linux-arm64` build from Anthropic, patches its ELF interpreter to Termux's
glibc loader so the kernel can exec it directly, and routes Claude's
embedded-tool re-execs (`grep`/`find`/`rg`) back through the launcher.

## Legal

This project ships **only its own shell scripts**. The Claude Code binary is
**downloaded directly from Anthropic** at install/first-run and patched locally
on your device for interoperability — it is **not redistributed by this
project**. Your use of Claude Code is governed by
[Anthropic's Commercial Terms of Service](https://www.anthropic.com/legal/commercial-terms);
this project only automates the download and the local patch.

This is the author's engineering reasoning, not legal advice.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/gtbuchanan/claude-code-termux/main/install.sh | bash
claude
```

`install.sh` enables the glibc package repo (the `glibc-repo` package), then
downloads the latest release `.deb` and installs it with `apt`, which pulls
`glibc-runner`, `patchelf-glibc`, `jq`, and `python3` automatically. No manual
dependency install is needed. The package's postinstall then downloads and
patches the Claude Code binary, so `claude` works immediately.

`glibc-runner` and `patchelf-glibc` are not in Termux's default repos — they
live in [termux-pacman/glibc-packages](https://github.com/termux-pacman/glibc-packages),
exposed to apt by the `glibc-repo` package. The installer enables it for you;
it cannot be a package `Depends`, because apt resolves dependencies before a
newly-added repo would be visible.

### Pinning the Claude Code version

The package tracks the **latest** Claude Code release by default. To pin a
specific version, edit `$PREFIX/etc/claude-code-termux.conf`:

```sh
CLAUDE_CODE_VERSION=2.1.153
```

then run `claude-code-termux-update`. The `CLAUDE_CODE_VERSION` environment
variable overrides the config file for one-off installs.

### Caching the Claude Code download

The binary is ~240 MB. To avoid re-downloading it on reinstalls or version
rollbacks — handy on slow or metered mobile connections — point
`CLAUDE_CODE_CACHE_DIR` (in `$PREFIX/etc/claude-code-termux.conf`, or the
environment) at a directory to cache it in:

```sh
CLAUDE_CODE_CACHE_DIR=$PREFIX/var/cache/claude-code-termux
```

The cache holds the verified, pre-patch bytes; the ELF patch is still re-applied
on every install, and a corrupt or stale entry is detected by its SHA-256 and
re-downloaded. Leave it empty (the default) to disable caching.

## How it works

1. `apt` installs the compiled launcher (`claude`), the bootstrap + patch
   helpers, and a config file, pulling the runtime dependencies.
1. The package's postinstall downloads the `linux-arm64` binary from Anthropic,
   verifies its SHA-256, points its ELF interpreter at Termux's glibc loader
   (`patchelf`), and blanks the subprocess `CLAUDE_CODE_EXECPATH` assignment
   (`patch-execpath.py`) so embedded-tool re-execs route back through the
   launcher.
1. The compiled launcher execs the patched binary with `LD_PRELOAD` cleared,
   preserving `argv[0]` so Claude's `grep`/`find`/`rg` dispatch works, and sets
   `TMPDIR`/`CLAUDE_CODE_TMPDIR` to the Termux prefix (only when unset) since
   Termux has no writable `/tmp`.
1. The postinstall also symlinks the launcher onto Anthropic's native-install
   path (`~/.local/bin/claude`) so Claude's health check passes when it detects
   `installMethod: native`. The symlink targets the launcher (not the patched
   binary), so the env setup still applies, and `autoUpdates: false` keeps the
   native self-updater from replacing it with a stock glibc build. A
   user-managed regular file at that path is left untouched.

Update later with `claude-code-termux-update`. It re-downloads and re-patches
only when the resolved version (latest, or your pin) differs from what's
installed, so it's safe to run unattended on a schedule — e.g. a daily
`termux-job-scheduler` job or a `cron` entry. Pass `--force` to re-apply the
current version (e.g. to repair a corrupted binary).

### Settings merged into `~/.claude/settings.json`

On install the package merges two keys Claude needs on Termux (skip with
`CLAUDE_CODE_SKIP_SETTINGS=1`, e.g. when a dotfile manager owns the file):

- `env.LD_PRELOAD` → `libtermux-exec-ld-preload.so`. Re-arms termux-exec for
  **subprocesses** so `#!/usr/bin/env …` shebangs (pnpm, npx, …) resolve.
- `autoUpdates` → `false`. The in-session updater would otherwise overwrite the
  ELF-patched binary with a stock glibc one that won't exec.

If you set a custom `statusLine.command`, invoke it via `bash` explicitly (e.g.
`bash ~/.claude/statusline`) so the kernel never resolves a `/usr/bin/env`
shebang — there is no termux-exec preload inside the glibc claude process.

## Known limitations

- **MCP browser bridge.** Claude hardcodes the MCP browser-bridge socket under
  `/tmp` with no env override, so that one feature can't write on Termux (where
  `/tmp` is unwritable). General temp use is fine — the launcher points
  `TMPDIR`/`CLAUDE_CODE_TMPDIR` at the Termux prefix, which covers Claude's
  `os.tmpdir()` resolver and its sandbox subprocess. See
  [anthropics/claude-code#15637](https://github.com/anthropics/claude-code/issues/15637).

## Consumer setup (dotfiles)

Drive the install from a dotfile manager and own `settings.json` yourself by
skipping the package's merge (`CLAUDE_CODE_SKIP_SETTINGS=1`) so your dotfiles
become the single source for the
[keys it would otherwise add](#settings-merged-into-claudesettingsjson).

For a worked example, the author's dotfiles install the package with
[chezmoi](https://www.chezmoi.io), pinning both versions for
[Renovate](https://docs.renovatebot.com) and re-applying on a bump. The
[Android: claude-code-termux Package](https://github.com/gtbuchanan/dotfiles/blob/main/docs/claude-code.md#android-claude-code-termux-package)
doc walks through it, backed by the
[version pins](https://github.com/gtbuchanan/dotfiles/blob/main/home/.chezmoidata/claude-code.yaml)
and [install script](https://github.com/gtbuchanan/dotfiles/blob/main/home/.chezmoiscripts/android/run_onchange_after_claude-code-install.sh.tmpl).

## Uninstall

```bash
pkg uninstall claude-code-termux
```

This removes the launcher, the downloaded binary, and the native-path symlink
(`~/.local/bin/claude`, only if it still points at the launcher).
`~/.claude/settings.json` is left untouched.

## Prerequisites

- Termux on Android, **aarch64**
- Network access — the installer enables the `glibc-repo` apt source and
  fetches Claude Code from Anthropic. `glibc-runner` (the glibc loader),
  `patchelf-glibc`, `jq`, and `python3` are then installed automatically as
  package dependencies.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev environment (mise), the
`lint`/`build` tasks, and how the package is built and tested.

## License

The scripts in this repository are MIT-licensed — see [LICENSE](LICENSE). This
covers only this project's code, not Claude Code (see [Legal](#legal)).
