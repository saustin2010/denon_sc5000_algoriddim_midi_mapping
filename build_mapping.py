#!/usr/bin/env python3
"""Build the SC5000M -> djay mapping from an explicit control table.

Every target is checked against the keyPath vocabulary djay itself uses -- read out of
the mappings inside djay Pro.app. A keyPath djay does not know is accepted by the file
format and then silently ignored, so the button simply does nothing; --check re-verifies
the whole table against the installed djay and fails loudly if a target has gone stale.

Layout: midiproxy latches LAYER and rewrites the channel, so deck N arrives on MIDI
channel N and one physical deck can drive up to four. Library and application controls
are global but must be repeated on every channel, since the proxy re-channels
everything. Keep --layers in step with midiproxy's.
"""
import argparse, glob, os, plistlib, re, sys
from pathlib import Path

V = "VERIFIED"

# note, target, verified?, LED feedback?
DECK_NOTES = [
    (1,  "playPause",                              V, True),
    (2,  "cuePositionOrJumpConsideringPlayState1", V, True),
    (3,  "skipBackward",                           V, True),
    (4,  "skipForward",                            V, True),
    (5,  "loadPreviousTrack",                      V, True),
    (6,  "loadNextTrack",                          V, True),
    (7,  "censor",                                 V, True),
    (8,  "loopIn",                                 V, True),
    (9,  "loopOutAndReloopOrUnloop",               V, True),
    (10, "autoLoopOnOff",                          V, True),
    (19, "jogPitchBendModeToggle",                 V, True),
    (20, "bpmSync",                                V, True),
    (21, "turntableIsSyncMaster",                  V, True),
    (22, "key",                                    V, True),
    (23, "deckSlipToggle",                         V, True),
    (24, "pitchBendMinus",                         V, True),
    (25, "pitchBendPlus",                          V, True),
    (27, "padModeHotCue",                          V, True),
    (28, "padModeBounceLoop",                      V, True),
    (29, "padModeSlicer",                          V, True),
    (30, "padModeAutoLoop",                        V, True),
    (40, "scratchingMode",                         V, False),
]
# Performance pads. djay switches its own pads with an internal "modifier2" that only
# its compiled per-device classes can set, so a mapping file cannot follow the pad-mode
# buttons on its own. midiproxy holds the mode instead and re-addresses the pads into
# one of these note ranges; each bank therefore gets eight independent targets.
# The base notes must match padModeBase in midiproxy.swift.
ROLL  = ["003125", "00625", "0125", "025", "05", "1", "2", "4"]
ALOOP = ["025", "05", "1", "2", "4", "8", "16", "32"]

# base note, name, eight targets, eight SHIFT targets (or None)
PAD_BANKS = [
    (32, "hot cue",   [f"cueOrJumpIfAlreadySet{i+1}" for i in range(8)],
                      [f"clearCuePoint{i+1}"         for i in range(8)]),
    (80, "roll",      [f"bounceLoop{b}BeatInterval"  for b in ROLL],  None),
    (88, "slicer",    [f"slicer8Slice{i+1}"          for i in range(8)], None),
    (96, "auto loop", [f"autoLoop{b}BeatInterval"    for b in ALOOP], None),
]

DECK_CCS = [
    (3,  "autoLoopDurationRotary", "rotary",          V),
    (8,  "speed",                  None,              V),
    (49, "scratchingMove",         "rotary-absolute", V),
    (64, "skipRotary",             "rotary-absolute", V),
]

# global controls, mapped on both channels. load1/load2 follow the active deck.
SHIFTED_NOTES = [
    # panel prints "RANGE" under the PITCH BEND -/+ pair
    (24, "application.tempoSliderRangeMinus", V),
    (25, "application.tempoSliderRangePlus",  V),
]

GLOBAL_NOTES = [
    (13, "musicLibrary.nextSource",                V),
    (14, "musicLibrary.toggleLibraryVisible",      V),
    (16, "musicLibrary.libraryBack",               V),
    (17, "musicLibrary.focusTracks",               V),
    (12, "musicLibrary.markUnmarkSelectedSongs",   V),
]
GLOBAL_CCS = [(6, "musicLibrary.libraryRotary", "rotary", V)]

SHIFT_NOTE = 26

DJAY_MAPPINGS = "/Applications/djay Pro.app/Contents/Resources/MIDI Mappings"


def known_keypaths(folder=DJAY_MAPPINGS):
    """Every keyPath djay's own bundled mappings use, with the deck index folded
    away so turntable1/2/Selected all collapse to one name. A keyPath outside this
    set is not rejected by djay — it is accepted and then silently does nothing."""
    found = set()
    for f in glob.glob(os.path.join(folder, "*.djayMidiMapping")):
        try:
            d = plistlib.load(open(f, "rb"))
        except Exception:
            continue
        for c in d.get("controls", []) + d.get("outputs", []):
            if kp := c.get("keyPath"):
                found.add(re.sub(r"^turntable(?:[1-4]|Selected)\.", "T.", kp))
    return found


def check(controls, folder=DJAY_MAPPINGS):
    """Returns the controls whose target djay has never heard of."""
    known = known_keypaths(folder)
    if not known:
        return None                       # djay not installed here; nothing to check against
    dead, seen = [], set()
    for c in controls:
        kp = c["keyPath"]
        folded = re.sub(r"^turntable[1-4]\.", "T.", kp)
        if folded not in known and folded not in seen:
            seen.add(folded)
            dead.append((c["midiMessageType"], c["midiData"], kp))
    return dead


def ctl(ch, mtype, data, keypath, ctype=None, out=False, modifier=False):
    e = {"midiChannel": ch, "midiMessageType": mtype, "midiData": data, "keyPath": keypath}
    if ctype:    e["controlType"] = ctype
    if out:      e["output"] = {}
    if modifier: e["modifier"] = True
    return e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dest", type=Path)
    ap.add_argument("-n", "--name", default="SC5000M Proxy")
    ap.add_argument("-u", "--usbid", type=int, default=0)
    ap.add_argument("-L", "--layers", type=int, default=2, choices=(2, 3, 4),
                    help="decks the LAYER button cycles; must match midiproxy --layers")
    args = ap.parse_args()

    controls = []
    for ch in range(args.layers):
        deck = f"turntable{ch + 1}"
        for note, tgt, _, led in DECK_NOTES:
            controls.append(ctl(ch, 1, note, f"{deck}.{tgt}", out=led))
        for base, _, targets, shifted in PAD_BANKS:
            for i, tgt in enumerate(targets):
                controls.append(ctl(ch, 1, base + i, f"{deck}.{tgt}", out=True))
                if shifted:
                    controls.append(ctl(ch, 1, base + i, f"{deck}.{shifted[i]}", modifier=True))
        for cc, tgt, ctype, _ in DECK_CCS:
            controls.append(ctl(ch, 3, cc, f"{deck}.{tgt}", ctype=ctype))
        # library load follows whichever deck you are on
        controls.append(ctl(ch, 1, 18, f"musicLibrary.load{ch+1}", out=True))
        # globals need to exist on both channels because the proxy re-channels
        for note, tgt, _ in SHIFTED_NOTES:
            controls.append(ctl(ch, 1, note, tgt, modifier=True))
        for note, tgt, _ in GLOBAL_NOTES:
            controls.append(ctl(ch, 1, note, tgt, out=True))
        for cc, tgt, ctype, _ in GLOBAL_CCS:
            controls.append(ctl(ch, 3, cc, tgt, ctype=ctype))
        controls.append(ctl(ch, 1, SHIFT_NOTE, "application.modifier"))

    plist = {
        "endpointName": args.name,
        "schemeVersion": 1,
        "USBID": args.usbid,
        "version": 0,
        "editor": "sc5000_midi build_mapping.py",
        "controls": controls,
    }
    dead = check(controls)
    if dead:
        print("REFUSING TO WRITE — djay has no such targets; these buttons would do nothing:")
        for mtype, data, kp in dead:
            print(f"  {'note' if mtype == 1 else 'cc  '} {data:>3}   {kp}")
        sys.exit(1)

    args.dest.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))

    per_deck = len(controls) // args.layers
    print(f"endpoint  {args.name!r}  USBID {args.usbid}")
    print(f"controls  {len(controls)}  ({args.layers} decks x {per_deck})")
    print(f"  LED feedback on {sum(1 for c in controls if 'output' in c)} controls")
    print(f"  SHIFT layer on  {sum(1 for c in controls if c.get('modifier'))} controls")
    print("  pad banks       " + ", ".join(f"{n} @ {b}-{b + 7}" for b, n, _, _ in PAD_BANKS))
    print("  every target checked against djay's own mappings"
          if dead == [] else "  djay not installed — targets unchecked")
    print(f"\nwritten   {args.dest}")


if __name__ == "__main__":
    main()
