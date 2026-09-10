#!/bin/bash
# Restart the proxy with new feel settings.
#   ./tune.sh <scale> [idle] [motor]
#     scale  platter movement per step. Higher = less sensitive. (default 32)
#     idle   seconds of stillness before scratch releases.       (default 0.35)
#     motor  "motor" to drive the platter from play state, anything else to leave it off
cd "$(dirname "$0")"
pkill -f midiproxy 2>/dev/null
sleep 0.6
MOTOR=""
[ "$3" = "motor" ] && MOTOR="--motor"
nohup ./midiproxy --scratch-scale "${1:-32}" --scratch-idle "${2:-0.35}" $MOTOR > /tmp/midiproxy.log 2>&1 &
sleep 1.5
grep -E "^jog|^motor|^gate" /tmp/midiproxy.log
