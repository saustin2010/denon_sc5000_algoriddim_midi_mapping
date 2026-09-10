#!/bin/bash
# Restart the proxy with new feel settings.
#   ./tune.sh <scale> [idle] [motor]
#     scale  platter ticks folded into one CC step. Higher = less sensitive.
#            Pairs with the mapping's rotarySensitivity, which MULTIPLIES: keep
#            that >= 1.0 or steps round away against djay's grid and the platter
#            feels lumpy. 2.4 ticks/step against sensitivity 1.0 is 1:1 vinyl.
#                                                                    (default 2.4)
#     idle   seconds of stillness before scratch releases.           (default 0.35)
#     motor  "motor" to drive the platter from play state, anything else to leave it off
cd "$(dirname "$0")"
# The LaunchAgent has KeepAlive, so it has to be stood down or launchd just restarts
# its own copy alongside the one we start here and the two fight over the deck.
launchctl bootout "gui/$UID/com.sc5000.midiproxy" 2>/dev/null
pkill -f midiproxy 2>/dev/null
sleep 0.6
MOTOR=""
[ "$3" = "motor" ] && MOTOR="--motor"

# Decks must match the mapping djay actually loaded, or the extra decks are simply
# unreachable — the proxy re-channels to a deck the mapping never binds. Read the
# count out of the deployed file rather than trusting a default to stay in step.
DEST=~/Library/Containers/com.algoriddim.djay-iphone-free/Data/Music/djay/MIDI\ Mappings
LAYERS=$(python3 - "$DEST" <<'PY' 2>/dev/null || echo 2
import plistlib,glob,sys
best=0
for p in glob.glob(sys.argv[1]+"/SC5000M_Proxy*.djayMidiMapping"):
    d=plistlib.load(open(p,'rb'))
    best=max(best, len({c.get('midiChannel',0) for c in d.get('controls',[])}))
print(best if 2 <= best <= 4 else 2)
PY
)
echo "decks: $LAYERS  (read from the mapping djay has)"

nohup ./midiproxy --layers "$LAYERS" --scratch-scale "${1:-2.4}" \
      --scratch-idle "${2:-0.35}" $MOTOR > /tmp/midiproxy.log 2>&1 &
sleep 1.5
grep -E "^layer|^jog|^motor|^gate" /tmp/midiproxy.log
echo
echo "when it feels right, put that number in midiproxy.swift and restore the agent:"
echo "  ./install_agent.sh $LAYERS"
