# Contributing to claude-code-termux

## Prerequisites

[mise] pins the only host-side dev tool — `shellcheck` — and runs the dev
tasks. **Docker** is also required to build the `.deb` on a non-Termux host (the
build runs in a Termux environment, which a dev host obtains via
`termux/termux-docker:aarch64`; see [Building and testing](#building-and-testing)).

Install mise:

- **Windows** — `winget install jdx.mise`
- **macOS** — `brew install mise`
- **Linux** — `curl https://mise.run | sh`
- **Termux/Android** — see [Termux/Android setup](#termuxandroid-setup)

Then trust the repo config and install the pinned tools:

```sh
mise trust
mise install
```

`mise install` reads `mise.toml` + `mise.lock` and verifies each downloaded
binary against the recorded sha256. `[settings] lockfile = true` keeps the
lockfile self-perpetuating: a local `mise.toml` edit re-runs through `mise
install` and rewrites `mise.lock`. CI runs with `MISE_LOCKED=1` and fails loudly
on any drift between the two files (analogous to a frozen lockfile), so commit
the regenerated `mise.lock` alongside any tool change.

## Tasks

The dev workflow runs through file-based mise tasks in `mise-tasks/`:

- `mise run lint` — shellcheck every tracked shell script. Fast, host-side, no
  Docker; runs anywhere.
- `mise run build [version]` — the full pipeline: compile the launcher, assemble
  the `.deb`, install it via the real `install.sh`, and assert every fix.
  `version` is optional; empty derives the local CalVer (`scripts/version.sh`,
  run number `0`).

## Building and testing

`mise run build` is the canonical pre-PR check. The package is hand-assembled
and the build + install + assertions all run **in a Termux environment** — it
needs Termux's clang + bionic for the C launcher. One rule, two ways in:

- **On a Termux/Android device** — `build` runs `scripts/test.sh` natively
  (`pkg install clang dpkg` first).
- **On a dev host** (Windows/macOS/Linux, any arch) — `build` runs
  `scripts/test-docker.sh`, which spins up `termux-docker` and runs the same
  `scripts/test.sh` inside it. Native on arm64 hosts, under QEMU elsewhere. CI
  runs the same thing on a native arm64 runner.

The output `.deb` lands in `artifacts/packages/` (git-ignored). It contains
**none of Anthropic's bytes** — the Claude Code binary is downloaded and patched
on-device at install time, never rehosted. Never commit or publish that binary.

## Versioning and releases

CalVer `YYYY.M.<counter>`, where `<counter>` is the CI run number or `0`
locally. There is **no version file to bump**. Releases are cut by approving the
`release` environment gate on a push to `main`; `cd.yml` ships the exact
artifact that CI built and tested — it does not rebuild.

[mise]: https://mise.jdx.dev

## Termux/Android setup

mise's downloaded binaries are standard Linux builds that hardcode `/lib`,
`/usr`, etc. Termux's prefix is `/data/data/com.termux/files/usr`, so those
paths don't resolve without a chroot wrapper. Add this to your shell rc so
`mise` always runs through `termux-chroot` (`pkg install termux-chroot` first):

```sh
mise() { SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" termux-chroot command mise "$@"; }
```
