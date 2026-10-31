#!/bin/bash
# Rebuild the mapping and the proxy, and copy the mapping where djay looks for it.
#   ./deploy.sh
#
# The mapping always binds all four decks. How many LAYER cycles through is the
# proxy's "decks" preference (http://localhost:8750), which changes live — so moving
# between two and four decks never needs a rebuild or a re-select in djay.
#
# djay reads a mapping when you SELECT it and caches it from then on, so a file
# rewritten underneath a running djay changes nothing. This script says so at the end
# rather than leaving you to wonder why the new controls are dead.
set -e
cd "$(dirname "$0")"
DEST=~/Library/Containers/com.algoriddim.djay-iphone-free/Data/Music/djay/MIDI\ Mappings
MAP=SC5000M_Proxy_4DECK.djayMidiMapping

./build_mapping.py --layers 4 "$MAP"
swiftc -O midiproxy.swift -o midiproxy
cp "$MAP" "$DEST/"

# Only ever leave one proxy mapping where djay can see it. Every variant has to claim
# the endpointName "SC5000M Proxy" — that is the real port name — so if two sit in the
# folder and djay ever loses its explicit binding, it name-matches and picks one
# arbitrarily. That is exactly how a mapping silently "reconfigures".
OTHER=SC5000M_Proxy_FULL.djayMidiMapping
if [ -f "$DEST/$OTHER" ]; then
    mkdir -p "$DEST/_disabled"
    mv "$DEST/$OTHER" "$DEST/_disabled/"
    echo "stood down  $OTHER  (kept in _disabled/)"
fi

# The running proxy is the old binary until it restarts. launchd brings it straight
# back, and it re-reads the prefs as it starts.
if launchctl print "gui/$UID/com.sc5000.midiproxy" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$UID/com.sc5000.midiproxy"
    echo "restarted the proxy"
fi

echo
echo "deployed  $MAP  ->  djay"
if pgrep -qf "djay Pro.app/Contents/MacOS"; then
    echo "djay is RUNNING and still holds the old mapping."
    echo "  -> Preferences > Devices > SC5000M Proxy: switch the mapping away and back."
    echo "     (re-selecting reads from disk; quitting djay may overwrite it instead)"
fi
