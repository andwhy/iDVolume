#!/bin/bash
# Stops iDVolume and removes it and its login agent.
set -uo pipefail

LABEL=local.idvolume
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x iDVolume 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/iDVolume.app"
echo "iDVolume removed (Accessibility entry can be deleted in System Settings)"
