#!/bin/zsh
# Installs the app and launch agent. A first install starts in dry-run mode; reinstalls keep the mode.
set -euo pipefail
root="${0:A:h}/.."
"$root/scripts/build-app.sh"

app="$HOME/Applications/TextStop.app"
plist="$HOME/Library/LaunchAgents/local.textstop.plist"
logs="$HOME/Library/Logs/textstop"
label="gui/$(id -u)/local.textstop"

launchctl bootout "$label" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$logs"
rm -rf "$app"
cp -R "$root/dist/TextStop.app" "$app"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.textstop</string>
    <key>ProgramArguments</key><array><string>$app/Contents/MacOS/textstop</string><string>run</string></array>
    <key>EnvironmentVariables</key><dict><key>TEXTSTOP_AGENT</key><string>1</string></dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>60</integer>
    <key>StandardOutPath</key><string>$logs/agent.log</string>
    <key>StandardErrorPath</key><string>$logs/agent.log</string>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null

echo
echo "Add $app under Full Disk Access in the window that's opening (press + and Cmd-Shift-G to paste the path)."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
printf "Press Return once it's added: "
read -r _

launchctl bootstrap "gui/$(id -u)" "$plist"
echo "Agent running (mode unchanged; see 'textstop status'). Approve the Messages automation prompt when it appears."
echo "Log: $logs/agent.log"
