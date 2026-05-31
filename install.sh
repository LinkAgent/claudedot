#!/bin/bash
# One-shot installer:
#   1. builds the .app
#   2. installs the hook script + app to stable locations
#   3. merges lifecycle hooks into ~/.claude/settings.json
#   4. registers a LaunchAgent so it starts at login, and launches it now
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="claudedot"
OLD_APP_NAME="ClaudeStatusBar"
INSTALL_APP_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_APP_DIR/$APP_NAME.app"
OLD_INSTALLED_APP="$INSTALL_APP_DIR/$OLD_APP_NAME.app"
HOOK_HOME="$HOME/.claude/statusbar"
HOOK_DEST="$HOOK_HOME/cc_statusbar_hook.py"
PLIST="$HOME/Library/LaunchAgents/com.claudecode.statusbar.plist"

PYTHON="$(command -v python3)"
if [ -z "$PYTHON" ]; then echo "python3 not found"; exit 1; fi

echo "==> [1/5] Building app"
bash "$ROOT/build.sh"

echo "==> [2/5] Installing hook + usage-probe scripts -> $HOOK_HOME"
mkdir -p "$HOOK_HOME/sessions"
cp "$ROOT/hook/cc_statusbar_hook.py" "$HOOK_DEST"
chmod +x "$HOOK_DEST"
cp "$ROOT/hook/cc_usage_probe.py" "$HOOK_HOME/cc_usage_probe.py"
chmod +x "$HOOK_HOME/cc_usage_probe.py"

echo "==> [3/5] Installing app -> $INSTALLED_APP"
mkdir -p "$INSTALL_APP_DIR"
# Stop a running instance so we can overwrite it.
pkill -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
pkill -f "$OLD_INSTALLED_APP/Contents/MacOS/$OLD_APP_NAME" 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALLED_APP"
rm -rf "$OLD_INSTALLED_APP"
cp -R "$ROOT/build/$APP_NAME.app" "$INSTALLED_APP"

echo "==> [4/5] Merging hooks into ~/.claude/settings.json"
python3 "$ROOT/install_hooks.py" "$PYTHON $HOOK_DEST"

echo "==> [5/5] Registering LaunchAgent + launching"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.claudecode.statusbar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <false/>
    <key>ProcessType</key>      <string>Interactive</string>
</dict>
</plist>
PL

# (Re)load the agent so RunAtLoad starts exactly one instance. bootout may fail
# if it isn't loaded yet; ignore. kickstart guarantees it's running afterwards.
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
sleep 0.3
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
launchctl kickstart "gui/$(id -u)/com.claudecode.statusbar" 2>/dev/null || true

echo ""
echo "Done. Look for the colored owl in your menu bar."
echo "  ⚪️ idle (dozing)   🟢 running   🟡 needs input   🔴 error"
echo "Hooks take effect for Claude Code sessions started from now on."
echo "Uninstall any time with: bash $ROOT/uninstall.sh"
