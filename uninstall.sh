#!/bin/sh
# Removes LocoHost completely: app, CLI link, preferences, rules, activity and review files, login item.
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/locohost/main/uninstall.sh | sh
set -u
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
if pgrep -x LocoHost >/dev/null 2>&1; then
  say "Stopping LocoHost"; open "locohost://login-off" 2>/dev/null; sleep 1; open "locohost://quit" 2>/dev/null || pkill -x LocoHost; sleep 1
fi
rm -rf "$HOME/Applications/LocoHost.app" "/Applications/LocoHost.app" "$HOME/.local/bin/locohost" "$HOME/Library/Application Support/LocoHost" 2>/dev/null
defaults delete no.guerrilla.locohost >/dev/null 2>&1
say "LocoHost removed."
