#!/bin/bash
# Cleanly remove everything install.sh added.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="claudedot"
OLD_APP_NAME="ClaudeStatusBar"
INSTALLED_APP="$HOME/Applications/$APP_NAME.app"
OLD_INSTALLED_APP="$HOME/Applications/$OLD_APP_NAME.app"
PLIST="$HOME/Library/LaunchAgents/com.claudecode.statusbar.plist"

echo "==> Stopping LaunchAgent + app"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$OLD_INSTALLED_APP/Contents/MacOS/$OLD_APP_NAME" 2>/dev/null || true

echo "==> Removing hooks from ~/.claude/settings.json"
python3 "$ROOT/install_hooks.py" --uninstall || true

echo "==> Removing files"
rm -f "$PLIST"
rm -rf "$INSTALLED_APP"
rm -rf "$OLD_INSTALLED_APP"
rm -f "$HOME/.claude/statusbar/cc_usage_probe.py" "$HOME/.claude/statusbar/usage.json"
rm -rf "$HOME/.claude/statusbar/probe"
echo "Removed app, LaunchAgent, hooks and the usage probe."
echo "(Session state in ~/.claude/statusbar/sessions left in place; delete it manually if you like.)"
