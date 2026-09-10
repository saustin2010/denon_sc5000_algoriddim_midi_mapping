# SC5000M → djay Pro

Drives a Denon SC5000M Prime from djay Pro on macOS, with more decks and more pad
modes than the deck's MIDI alone can express.

The deck in Computer mode is an ordinary MIDI controller with some rough edges: it
floods the host with platter rotation, it has no touch sensor to say whether a hand
is on the platter, its LAYER button is just a button, and its pad-mode buttons do not
change what the pads send. `midiproxy` sits between the deck and djay and fixes all
four, republishing the deck as a clean virtual MIDI port.

```
 SC5000M ──USB MIDI──▶ midiproxy ──virtual port "SC5000M Proxy"──▶ djay Pro
         ◀──LED/colour feedback──┘
```

## Set it up once

```sh
./deploy.sh              # build the mapping + proxy, copy the mapping to djay
./install_agent.sh       # start the proxy at login and keep it running
```

Then in djay, once: **Preferences → Devices → SC5000M Proxy**, select the mapping.
djay remembers that choice across restarts.

For four decks it is `./deploy.sh 4` and `./install_agent.sh 4` — the mapping and the
proxy have to agree on the deck count.

## From a cold boot

Nothing to run. The LaunchAgent starts `midiproxy --wait` at login, which sits waiting
if the deck is off and picks it up whenever it appears, in either order:

1. Turn on the Mac and log in — the proxy is already running.
2. Turn on the deck and put it in **Computer** mode (SOURCE → Computer). This is the
   only manual step; the deck does not always come up in Computer mode on its own.
3. Open djay. The mapping is still selected from last time.

Power-cycling the deck mid-session is fine: the proxy notices it has gone, exits, and
launchd starts a fresh copy that waits for it to come back.

```sh
tail -f /tmp/midiproxy.log                        # what the proxy is doing
launchctl print gui/$UID/com.sc5000.midiproxy     # is the agent healthy
./install_agent.sh --uninstall                    # stop starting it at login
```

**If the deck does nothing in djay**, check in this order: is there a line in
`/tmp/midiproxy.log` naming your deck; is the deck in Computer mode; is
"SC5000M Proxy" the selected device in djay's Devices pane.

> **djay caches a mapping when you select it.** Rewriting the file under a running
> djay changes nothing — the new controls are simply dead. Re-select the mapping in
> the Devices pane to reload it. Don't quit djay to do it: djay writes mapping files
> itself and may save its stale copy back over yours. `deploy.sh` reminds you of this.

## What the proxy does

**Layers → decks.** LAYER is consumed by the proxy and never reaches djay. It cycles
a counter and rewrites the MIDI channel, so deck N goes out on channel N and the host
sees independent decks. Up to four (`--layers`). The platter ring is tinted per deck
so the wheel says which one you are holding. Notes held across a switch get their
note-off on the layer they were pressed in.

**Pad modes → note banks.** djay re-points its own pads with an internal `modifier2`
that only its compiled per-device classes can set; a mapping file cannot touch it.
So the proxy holds the mode itself and re-addresses the pads:

| Bank | Notes | djay targets |
|---|---|---|
| HOT CUE | 32–39 | `cueOrJumpIfAlreadySet1–8`, SHIFT clears |
| ROLL | 80–87 | `bounceLoop003125…4BeatInterval` |
| SLICER | 88–95 | `slicer8Slice1–8` |
| LOOP | 96–103 | `autoLoop025…32BeatInterval` |

The mode buttons still pass through, so djay's on-screen pad mode follows along.

**Scratching.** The deck has no platter touch sensor, so the proxy synthesises one:
sustained rotation raises note 40 (`scratchingMode`), stillness drops it. CC 49 is
unwrapped and scaled by the measured 28.8 wraps per revolution so one turn of the
platter is one sweep, as a jog wheel reports.

**Motor gating** (`--motor`, off by default). While the motor drives the platter its
rotation is discarded — the deck cannot tell motor from hand, and the host would
otherwise seek at ~750 units/second. STOP MOTOR toggles between a spinning platter
and a free one.

## The tools

| | |
|---|---|
| `midiproxy.swift` | the proxy. `--help` documents every option |
| `build_mapping.py` | generates the djay mapping from one control table |
| `deploy.sh` | build + copy + tell you to re-select in djay |
| `midimon.swift` | live MIDI monitor; `-m <mapping>` labels each control with the djay target it hits |
| `ledtest.swift` | walks LEDs and colour indices — use it to pick ring/pad colours |
| `motorhunt.swift` | the CC sweep that found the platter motor |
| `screenprobe.swift` | reads the 7" screen's USB endpoints (see the spec) |
| `install_agent.sh` | LaunchAgent that keeps the proxy running across logins and deck power cycles |

## Mapping targets are verified at build time

djay accepts a `keyPath` it has never heard of and then silently ignores it — the
button just does nothing, with no error anywhere. An early version of this mapping had
19 of 30 controls dead for exactly that reason (`loopIn1`, `censor1`, `padModeRoll`…
all invented).

`build_mapping.py` now reads every keyPath out of djay's own bundled mappings in
`/Applications/djay Pro.app` and **refuses to write** if a target is not in that
vocabulary. If djay ever renames something, the build fails loudly instead of
producing a mapping with dead buttons.

## What is verified, and what is not

Everything in `PRIME_MIDI_SPEC.md` marked as discovered was confirmed on this
hardware by capture — including several things the LC6000 spec gets wrong for this
deck (notes 11–15, the absent platter touch sensor, the undocumented motor CCs).

Not solved: **the 7" screen.** It is a separate USB device (`15e4:a00a`, interface
"Denon DJ Remote Screen"), not reachable over MIDI at all. Its endpoints are the right
shape for host-drawn video and the interface claims cleanly from userspace, but it
stays silent until a host initialises it and the protocol is undocumented. djay ships
no driver for it. See the spec's final section for the full findings.

## macOS only

`midiproxy` is a macOS command-line binary using CoreMIDI virtual endpoints. It does
not run on iOS or iPadOS, and the mapping depends on it entirely — the layer channels,
the pad note banks and the synthesised scratch note all come from the proxy. Plugging
the deck straight into an iPad gives djay the raw deck, which needs a different and
much simpler mapping.
