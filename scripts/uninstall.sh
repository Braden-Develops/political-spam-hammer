#!/bin/zsh
# Removes the agent and app. Keeps state and logs; remove those by hand if you want them gone.
launchctl bootout "gui/$(id -u)/local.textstop" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/local.textstop.plist"
rm -rf "$HOME/Applications/TextStop.app"
echo "Removed. State: ~/Library/Application Support/textstop  Logs: ~/Library/Logs/textstop"
echo "Revoke leftovers with: tccutil reset All local.textstop"
