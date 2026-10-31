#!/bin/bash
# Install (or remove) the LaunchAgents that keep midiproxy and its prefs page running.
#   ./install_agent.sh
#   ./install_agent.sh --uninstall
#
# midiproxy --wait sits waiting when the deck is off and exits when it goes away, so
# launchd's KeepAlive is all the supervision needed: log in and the proxy is there,
# power-cycle the deck and it reconnects on its own.
#
# The prefs page (prefs_server.py, http://localhost:8750) runs alongside it, on this
# Mac only. Settings live in its prefs file rather than in the arguments below, so
# changing one never means reinstalling this.
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
LABEL=com.sc5000.midiproxy
PREFS_LABEL=com.sc5000.prefs
AGENTS="$HOME/Library/LaunchAgents"

if [ "$1" = "--uninstall" ]; then
    for L in "$LABEL" "$PREFS_LABEL"; do
        launchctl bootout "gui/$UID/$L" 2>/dev/null || launchctl unload "$AGENTS/$L.plist" 2>/dev/null || true
        rm -f "$AGENTS/$L.plist"
        echo "removed $L"
    done
    exit 0
fi

# agent <label> <log> <program> [args...]
agent() {
    local label=$1 log=$2; shift 2
    local args=""
    for a in "$@"; do args+="        <string>$a</string>"$'\n'; done
    cat > "$AGENTS/$label.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
$args    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$log</string>
    <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$AGENTS/$label.plist" 2>/dev/null || launchctl load "$AGENTS/$label.plist"
}

mkdir -p "$AGENTS"
agent "$LABEL" /tmp/midiproxy.log "$DIR/midiproxy" --wait
agent "$PREFS_LABEL" /tmp/sc5000-prefs.log /usr/bin/python3 "$DIR/prefs_server.py"

echo "installed $LABEL"
echo "  starts at login, waits for the deck, reconnects after a power cycle"
echo "  log:       /tmp/midiproxy.log"
echo "  status:    launchctl print gui/$UID/$LABEL | head"
echo "installed $PREFS_LABEL"
echo "  prefs:     http://localhost:8750"
echo "uninstall: ./install_agent.sh --uninstall"
