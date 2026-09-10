#!/usr/bin/env python3
"""Re-point a djay MIDI mapping at a different MIDI endpoint, dropping unwanted controls.

djay binds a mapping to hardware with two fields:
    endpointName   the CoreMIDI display name
    USBID          (usbVendorID << 16) | usbProductID
                   e.g. Denon 0x15E4, SC5000M 0x800A -> 0x15E4800A -> 367296522

A virtual CoreMIDI port has no USB identity, so USBID is 0 unless djay says otherwise.
"""
import argparse, plistlib, sys
from pathlib import Path


def parse_drop(spec):
    out = set()
    for part in filter(None, (s.strip() for s in spec.split(","))):
        kind, _, num = part.partition(":")
        if not num.isdigit():
            sys.exit(f"bad --drop item: {part!r} (want note:56 or cc:12)")
        t = {"note": 1, "cc": 3, "pitch": 6}.get(kind.lower())
        if t is None:
            sys.exit(f"bad --drop kind: {kind!r} (want note, cc or pitch)")
        out.add((t, int(num)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("-n", "--name", default="SC5000M Proxy", help="target endpointName")
    ap.add_argument("-u", "--usbid", type=int, default=0, help="target USBID (0 for virtual ports)")
    ap.add_argument("-d", "--drop", default="note:56", help="controls to strip, e.g. note:56,cc:12")
    args = ap.parse_args()

    plist = plistlib.loads(args.source.read_bytes())
    drop = parse_drop(args.drop)

    before = len(plist.get("controls", []))
    kept, removed = [], []
    for c in plist.get("controls", []):
        if (c.get("midiMessageType"), c.get("midiData")) in drop:
            removed.append(c)
        else:
            kept.append(c)

    old_name, old_id = plist.get("endpointName"), plist.get("USBID")
    plist["controls"] = kept
    plist["endpointName"] = args.name
    plist["USBID"] = args.usbid

    args.dest.write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_XML))

    print(f"source      {args.source.name}")
    print(f"endpoint    {old_name!r} (USBID {old_id})")
    print(f"         -> {args.name!r} (USBID {args.usbid})")
    print(f"controls    {before} -> {len(kept)}")
    for c in removed:
        kind = {1: "note", 3: "cc", 6: "pitch"}.get(c.get("midiMessageType"), "?")
        print(f"  dropped   {kind} {c.get('midiData')} -> {c.get('keyPath')}")
    print(f"outputs     {sum(1 for c in kept if 'output' in c)} controls carry LED feedback")
    print(f"written     {args.dest}")


if __name__ == "__main__":
    main()
