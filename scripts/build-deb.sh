#!/data/data/com.termux/files/usr/bin/bash
#
# Assemble the claude-code-termux .deb. Runs inside termux/termux-docker:aarch64
# alongside build-wrapper.sh (it stages the wrapper that build-wrapper.sh
# compiles with Termux's clang), hence the absolute Termux shebang.
#
#   ./build-deb.sh [version]     # defaults to scripts/version.sh (CalVer)
#
# The package version is the INSTALLER version, not the Claude Code version —
# Claude's version is resolved on-device at run time (latest, or pinned via
# /etc/claude-code-termux.conf or $CLAUDE_CODE_VERSION).
#
# The .deb is hand-assembled with `dpkg-deb --build` rather than debhelper:
# debhelper isn't available on Termux and would force a split build for a
# package that's just shell + one ~20-line C file. This is a GitHub-released
# bridge .deb, never destined for the Debian archive.
#
set -euo pipefail

# Termux defaults to umask 077, which would make the DEBIAN control directory
# 0700 and the redirected control/conffiles 0600 — dpkg-deb rejects a control
# directory outside 0755..0775 ("bad permissions"). Normalize to 022 so every
# mkdir/install -d and `>`-redirected file below is group/other-readable
# regardless of the caller's umask. (`install -m` modes are already explicit.)
umask 022

VERSION="${1:-$(bash "$(dirname "$0")/version.sh")}"
ARCH=aarch64
PKG=claude-code-termux
PREFIX_REL=data/data/com.termux/files/usr

root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/artifacts/build"
pkgdir="$root/artifacts/packages"
stage="$build/${PKG}_${VERSION}_${ARCH}"

# The compiled launcher wrapper must be built first (build-wrapper.sh, inside
# termux/termux-docker:aarch64) so the ELF matches the device.
[ -x "$build/claude" ] || {
  echo "error: $build/claude not found — run build-wrapper.sh first." >&2
  exit 1
}

# Reset only the staging tree, preserving the compiled wrapper at $build/claude.
rm -rf "$stage"
mkdir -p "$stage/DEBIAN" "$pkgdir"

# Control metadata + maintainer scripts.
sed "s/@VERSION@/$VERSION/" "$root/package/control" > "$stage/DEBIAN/control"
install -m 0755 "$root/package/postinst" "$stage/DEBIAN/postinst"
install -m 0755 "$root/package/postrm"   "$stage/DEBIAN/postrm"
printf '/%s/etc/%s.conf\n' "$PREFIX_REL" "$PKG" > "$stage/DEBIAN/conffiles"

# Payload, staged under the Termux prefix.
install -d "$stage/$PREFIX_REL/bin"
install -d "$stage/$PREFIX_REL/libexec/$PKG"
install -d "$stage/$PREFIX_REL/etc"
install -d "$stage/$PREFIX_REL/share/doc/$PKG"
install -m 0755 "$build/claude"                                     "$stage/$PREFIX_REL/bin/claude"
install -m 0755 "$root/package/payload/bin/claude-code-termux-update" "$stage/$PREFIX_REL/bin/claude-code-termux-update"
install -m 0755 "$root/package/payload/libexec/bootstrap.sh"          "$stage/$PREFIX_REL/libexec/$PKG/bootstrap.sh"
install -m 0755 "$root/package/payload/libexec/patch-execpath.py"     "$stage/$PREFIX_REL/libexec/$PKG/patch-execpath.py"
install -m 0644 "$root/package/payload/etc/claude-code-termux.conf"   "$stage/$PREFIX_REL/etc/$PKG.conf"
install -m 0644 "$root/README.md"                                   "$stage/$PREFIX_REL/share/doc/$PKG/README.md"

out="$pkgdir/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$stage" "$out"
echo "$out"
