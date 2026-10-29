#!/bin/bash
# Builds iDVolume, puts it in ~/Applications and starts it at every login.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=local.idvolume
DEST="$HOME/Applications/iDVolume.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

# A rebuild changes the ad-hoc signature, and with it the Accessibility
# grant, so an existing build is installed as is; run ./build.sh to update.
[ -d build/iDVolume.app ] || ./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x iDVolume 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R build/iDVolume.app "$DEST"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/iDVolume</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/iDVolume.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "installed to $DEST, starts at login"
