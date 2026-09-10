#!/usr/bin/env python3
"""Build a two-channel djay mapping to sit behind `midiproxy --layer`.

The proxy latches the LAYER button and rewrites the MIDI channel, so deck 2 is
reached by channel 2 rather than by holding a modifier. That frees SHIFT to be a
real shift layer on both decks.

  deck 1  -> channel 0, keyPath turntable1.*
  deck 2  -> channel 1, keyPath turntable2.*  (mirrors deck 1 exactly)
  SHIFT   -> application.modifier on BOTH channels, since the proxy re-channels it
"""
import argparse, copy, plistlib
from pathlib import Path

CONSUMED = {(1, 11), (1, 56)}   # LAYER eaten by the proxy; 56 is the heartbeat

# Pitch bend carries the platter's absolute angle and wraps once per revolution.
# Mapped alongside CC 54 it fights the relative delta and the host jumps wildly.
DROP_TYPES = {6}

# The platter's jog belongs on CC 54, the relative delta (1 = +1, 127 = -1).
# djay's own editor tends to leave it unassigned and put jog on pitch bend instead,
# which is the absolute angle and jumps on every revolution. Reassign it here.
REMAP = {}

# djay's own Denon mapping scratches with a pair: a note saying "hand on platter"
# and an ABSOLUTE position CC. The SC5000M reports absolute position on CC 49; the
# touch note does not exist on this hardware, so midiproxy synthesises it on note 40.
SCRATCH = [
    # Note 19 is the VINYL / STOP MOTOR button. In djay it flips the platter between
    # scratching and pitch-bend nudging — scratch to stop the track, nudge to ride
    # the beat — which is what the button means on real hardware.
    {"midiChannel": 0, "midiMessageType": 1, "midiData": 19,
     "keyPath": "turntable1.jogPitchBendModeToggle", "output": {}},
    {"midiChannel": 0, "midiMessageType": 1, "midiData": 40,
     "keyPath": "turntable1.scratchingMode"},
    {"midiChannel": 0, "midiMessageType": 3, "midiData": 49,
     "controlType": "rotary-absolute", "keyPath": "turntable1.scratchingMove"},
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("-n", "--name", default="SC5000M Proxy")
    ap.add_argument("-u", "--usbid", type=int, default=0)
    args = ap.parse_args()

    plist = plistlib.loads(args.source.read_bytes())
    src = plist.get("controls", [])

    deck1, shift, skipped, remapped = [], [], [], []
    for c in src:
        key = (c.get("midiMessageType"), c.get("midiData"))
        kp = c.get("keyPath", "")
        if key in CONSUMED:
            skipped.append((c, "consumed by proxy"))
            continue
        if c.get("midiMessageType") in DROP_TYPES:
            skipped.append((c, "pitch bend — absolute platter angle, conflicts with CC 54"))
            continue
        if c.get("modifier"):
            skipped.append((c, "old SHIFT-hold deck 2 entry"))
            continue
        if kp == "application.modifier":
            shift.append(c)
            continue
        if key in REMAP:
            c = {**c, **REMAP[key]}
            kp = c["keyPath"]
            remapped.append(key)
        if "." not in kp:
            skipped.append((c, "unassigned placeholder"))
            continue
        if not kp.startswith("turntable1"):
            skipped.append((c, f"unexpected keyPath {kp}"))
            continue
        e = copy.deepcopy(c)
        e.pop("modifier", None)
        e["midiChannel"] = 0
        deck1.append(e)

    deck1 += [copy.deepcopy(c) for c in SCRATCH]

    deck2 = []
    for c in deck1:
        e = copy.deepcopy(c)
        e["midiChannel"] = 1
        e["keyPath"] = "turntable2" + c["keyPath"][len("turntable1"):]
        deck2.append(e)

    shift_out = []
    for c in shift:
        for ch in (0, 1):
            e = copy.deepcopy(c)
            e.pop("modifier", None)
            e["midiChannel"] = ch
            shift_out.append(e)

    plist["controls"] = deck1 + deck2 + shift_out
    plist["endpointName"] = args.name
    plist["USBID"] = args.usbid
    args.dest.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))

    print(f"source    {args.source.name}  ({len(src)} controls)")
    print(f"endpoint  {args.name!r}  USBID {args.usbid}\n")
    print(f"  deck 1 (ch 1)   {len(deck1):>3} controls, {sum('output' in c for c in deck1)} with LED feedback")
    print(f"  deck 2 (ch 2)   {len(deck2):>3} controls, {sum('output' in c for c in deck2)} with LED feedback")
    print(f"  SHIFT           {len(shift_out):>3} entries (modifier on both channels)")
    print(f"  total           {len(plist['controls']):>3}\n")
    reasons = {}
    for c, why in skipped:
        reasons.setdefault(why, []).append(c.get("midiData"))
    for why, data in reasons.items():
        print(f"  dropped {len(data):>2}  {why}")
    print(f"  added       3  scratch pair + VINYL mode toggle (note 19)")
    for t, n in remapped:
        print(f"  remapped   {'cc' if t == 3 else 'note'} {n} -> {REMAP[(t, n)]['keyPath']}")
    print(f"\nwritten   {args.dest}")


if __name__ == "__main__":
    main()
