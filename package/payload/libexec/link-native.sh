#!/data/data/com.termux/files/usr/bin/bash
#
# link-native.sh: reconcile Anthropic's native-install path
# (~/.local/bin/claude) onto our launcher.
#
# Claude's health check treats installMethod=native as a fatal error when this
# path is missing or invalid; pointing it at the launcher, not the patched
# binary directly, keeps the TMPDIR/LD_PRELOAD/argv[0] setup intact.
#
# Idempotent and safe to run both at install (postinst) and on every update
# (claude-code-termux-update). Running it from the schedulable update means a
# native self-updater that clobbers or repoints the symlink gets repaired on the
# next update; autoUpdates=false should prevent that, but this is a cheap second
# layer. Only a missing path or an existing symlink is touched; a user-managed
# regular file there is left untouched.
#
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
: "${HOME:=$PREFIX/../home}"
WRAPPER="$PREFIX/bin/claude"
NATIVE_LINK="$HOME/.local/bin/claude"

if [ -L "$NATIVE_LINK" ] || [ ! -e "$NATIVE_LINK" ]; then
  mkdir -p "$(dirname "$NATIVE_LINK")"
  ln -sfn "$WRAPPER" "$NATIVE_LINK"
else
  echo "claude-code-termux: $NATIVE_LINK exists and is not a symlink; leaving it unchanged." >&2
fi
