#!/bin/bash
# Install (or remove) a LaunchAgent that keeps midiproxy running.
#   ./install_agent.sh [layers]    layers: 2 (default) or 4
#   ./install_agent.sh --uninstall
#
# midiproxy --wait sits waiting when the deck is off and exits when it goes away, so
# launchd's KeepAlive is all the supervision needed: log in and the proxy is there,
# power-cycle the deck and it reconnects on its own.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL=com.sc5000.midiproxy
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL"
    exit 0
fi

LAYERS="${1:-2}"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DIR/midiproxy</string>
        <string>--wait</string>
        <string>--layers</string>
        <string>$LAYERS</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/midiproxy.log</string>
    <key>StandardErrorPath</key><string>/tmp/midiproxy.log</string>
</dict>
</plist>
PLISTEOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
echo "installed $LABEL  ($LAYERS decks)"
echo "  starts at login, waits for the deck, reconnects after a power cycle"
echo "  log:       /tmp/midiproxy.log"
echo "  status:    launchctl print gui/$UID/$LABEL | head"
echo "  uninstall: ./install_agent.sh --uninstall"
