#!/bin/bash
# Rebuild the mapping and the proxy, and copy the mapping where djay looks for it.
#   ./deploy.sh [layers]     layers: 2 (default) or 4 — must match midiproxy --layers
#
# djay reads a mapping when you SELECT it and caches it from then on, so a file
# rewritten underneath a running djay changes nothing. This script says so at the end
# rather than leaving you to wonder why the new controls are dead.
set -e
cd "$(dirname "$0")"
LAYERS="${1:-2}"
DEST=~/Library/Containers/com.algoriddim.djay-iphone-free/Data/Music/djay/MIDI\ Mappings
[ "$LAYERS" = 4 ] && MAP=SC5000M_Proxy_4DECK.djayMidiMapping || MAP=SC5000M_Proxy_FULL.djayMidiMapping

./build_mapping.py --layers "$LAYERS" "$MAP"
swiftc -O midiproxy.swift -o midiproxy
cp "$MAP" "$DEST/"

# Only ever leave one proxy mapping where djay can see it. Both variants have to
# claim the endpointName "SC5000M Proxy" — that is the real port name — so if both
# sit in the folder and djay ever loses its explicit binding, it name-matches and
# picks one arbitrarily. That is exactly how a mapping silently "reconfigures".
OTHER=SC5000M_Proxy_FULL.djayMidiMapping
[ "$LAYERS" = 4 ] || OTHER=SC5000M_Proxy_4DECK.djayMidiMapping
if [ -f "$DEST/$OTHER" ]; then
    mkdir -p "$DEST/_disabled"
    mv "$DEST/$OTHER" "$DEST/_disabled/"
    echo "stood down  $OTHER  (kept in _disabled/)"
fi

echo
echo "deployed  $MAP  ->  djay"
if pgrep -qf "djay Pro.app/Contents/MacOS"; then
    echo "djay is RUNNING and still holds the old mapping."
    echo "  -> Preferences > Devices > SC5000M Proxy: switch the mapping away and back."
    echo "     (re-selecting reads from disk; quitting djay may overwrite it instead)"
fi
