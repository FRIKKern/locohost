#!/bin/sh
# LocoHost installer: builds from source with clang (no Gatekeeper quarantine),
# installs to ~/Applications plus a `locohost` CLI in ~/.local/bin, launches, and verifies.
#
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/locohost/main/install.sh | sh
#
# Options (env vars, so they work through a pipe):
#   LOCOHOST_REF=v0.1.0     git ref to install (default: main)
#   LOCOHOST_NO_LAUNCH=1    build and install only
#   LOCOHOST_LOGIN=1        also register Launch at Login
set -eu

REPO="https://github.com/FRIKKern/locohost"
REF="${LOCOHOST_REF:-main}"
DEST="$HOME/Applications/LocoHost.app"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "LocoHost is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 13 ] || die "macOS 13 or newer required (found $(sw_vers -productVersion))."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
  say "Command Line Tools are missing. Opening Apple's installer; re-run this script when it finishes."
  xcode-select --install 2>/dev/null || true
  die "Command Line Tools not installed yet."
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say "Fetching $REPO@$REF"
curl -fsSL "$REPO/archive/$REF.tar.gz" | tar -xz -C "$TMP" --strip-components=1

say "Building (clang, universal)"
(cd "$TMP" && sh build.sh --no-install >/dev/null)

if pgrep -x LocoHost >/dev/null 2>&1; then
  say "Stopping running LocoHost"
  open "locohost://quit" 2>/dev/null || pkill -x LocoHost || true
  sleep 1
fi

say "Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$TMP/build/LocoHost.app" "$DEST"

[ "${LOCOHOST_NO_LAUNCH:-0}" = "1" ] && { say "Installed. Launch with: open $DEST"; exit 0; }

say "Launching"
open "$DEST"
sleep 2
[ "${LOCOHOST_LOGIN:-0}" = "1" ] && { open "locohost://login-on"; say "Registered Launch at Login (macOS may ask you to approve it once)."; }

sleep 1
mkdir -p "$HOME/.local/bin"; ln -sf "$DEST/Contents/MacOS/LocoHost" "$HOME/.local/bin/locohost"
if pgrep -x LocoHost >/dev/null 2>&1; then
  say "Verified: LocoHost is running. Look for the network icon and a count in your menu bar. CLI: ~/.local/bin/locohost list"
else
  say "Installed. Launch with: open $DEST"
fi
