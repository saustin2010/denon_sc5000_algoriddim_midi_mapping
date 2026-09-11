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
>
> This is not theoretical — a djay restart mid-session has been observed replacing a
> freshly deployed mapping with its cached copy, silently reverting the change. If
> there is only one mapping listed and nothing to switch away to, `deploy.sh` a second
> copy under another name, select that, then select back, and delete the spare. Two
> files claiming the endpoint name `SC5000M Proxy` is exactly the ambiguity
> `deploy.sh` otherwise protects you from, so do not leave it lying around.
>
> Proxy-side settings need none of this. `--scratch-scale`, `--scratch-idle`,
> `--motor` and `--layers` take effect on restart; only the mapping file needs a
> re-select.

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
| LOOP | 96–103 | `autoLoop00625…8BeatInterval` |

The mode buttons still pass through, so djay's on-screen pad mode follows along.

**Scratching.** The deck has no platter touch sensor, so the proxy synthesises one:
sustained rotation raises note 40 (`scratchingMode`), stillness drops it. Release is
the pickup — djay holds the track stopped until the note drops — and a real scratch
goes still for 1 ms median, 10 ms at the 99th percentile, so the default 50 ms
(`--scratch-idle`) clears anything a hand does by 5x while still feeling immediate.

**Platter gearing.** Two numbers multiply, and both live here:

| | |
|---|---|
| `--scratch-scale 2.4` | platter ticks folded into one CC step (proxy) |
| `rotarySensitivity 1.0` | djay's multiplier on each step (mapping) |

`rotarySensitivity` **multiplies** — higher is *more* sensitive. Read it off djay's own
mappings: counts-per-revolution × sensitivity is ~1500 on every one of them. Its
SC5000 mapping takes the coarse CC 17 (28.8 counts/rev) at 52.0; its RANE Four takes a
per-tick counter at 0.42, and 52/0.42 is the 128x between them.

Keep sensitivity at or above **1.0**. djay rounds each step to a whole internal unit,
so a step worth 0.42 rounds away two times in three and then lurches — it feels like
coarse, sticky grain, and no amount of tuning fixes it because the problem is the
rounding, not the gearing. Gear down with `--scratch-scale` instead: 2.4 ticks per
step against sensitivity 1.0 is 1:1 vinyl with every step landing on djay's grid.

**Turn slip on to scratch.** djay's slip mode keeps the track running underneath and
snaps back on release. Without it, scratching drags the playhead and the track has to
pick itself back up. It is the Slip button (note 23) — no menu needed.

**Motor** (`--motor`, off by default; SHIFT+Vinyl toggles it). The motor turns the
platter at 33 1/3 RPM to show a deck is playing, driven from djay's play LED — which
signals state by *steadiness*, not level: solid means playing, a 0.5 s blink means
paused, so `--motor-debounce` must outlast one blink half-period.

Even with `--motor` passed, it starts in **manual** mode. Motor mode costs you
scratching outright, so it has to be asked for. Spin-down ends when the platter stops
reporting rotation rather than after a fixed wait, so the platter frees up as soon as
it has actually stopped.

While it spins, **scratching is off**. The deck reports no touch, so the proxy cannot
tell your hand from the motor, and ungated a driven platter seeks through the track at
~2000 ticks/second. Motor and scratching are alternatives, not companions.

`--motor-touch` is an experimental attempt to have both, by learning the motor's rate
and forwarding only the residual. It is **off, and best left off**. It holds up while
nothing is touching the platter and fails at every edge: a hand sweeping through the
motor's own speed is indistinguishable from no hand, a throw produces residuals large
enough that djay misreads the 7-bit wrap and plays it backwards, and spin-down leaves
a stale rate over a platter that is no longer driven.

## The controls that are not obvious

Most of the panel does what it says. These do not:

| Control | Does |
|---|---|
| **Vinyl** (note 19) | platter mode: **lit = scratch**, dark = pitch bend |
| **SHIFT + Vinyl** | motor mode ↔ manual (only with `--motor`) |
| **Slip** (note 23) | djay slip mode — **turn this on to scratch** |
| **PITCH BEND −/+** | tempo nudge, in any mode |
| **SHIFT + PITCH BEND −/+** | tempo *range* − / + |
| **LAYER** | deck focus. Consumed by the proxy, never reaches djay |

The Vinyl lamp is **inverted** on its way to the deck. djay lights it to mean pitch
bend; the panel reads better with the light meaning the platter scratches.

The platter drives exactly one djay control at a time, chosen by that mode —
`scratchingMove` on CC 49 in scratch mode, `pitchBendMove` on CC 54 in pitch-bend mode.
Binding both at once is a trap worth knowing about: djay acts on every target that
matches, so a platter wired to two of them scratches *and* nudges tempo off one hand
movement, and a paused track runs away. The same fault with `jogSeekMove` is what made
an earlier build scrub through tracks instead of scratching.

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

## Getting off the Mac — see IOS_PORT_PLAN.md

iOS already enumerates the deck: `SC5000M Prime Controller Jack 1` appears over USB on
an iPhone in Computer mode. The engine is portable too — CoreMIDI and Foundation only,
no IOKit or AppKit anywhere — so what stands between here and running this off an iPad
is packaging, plus one unverified question about whether djay on iOS can load a custom
mapping at all. `IOS_PORT_PLAN.md` has the audit, the risks and a phased plan.

## macOS only

`midiproxy` is a macOS command-line binary using CoreMIDI virtual endpoints. It does
not run on iOS or iPadOS, and the mapping depends on it entirely — the layer channels,
the pad note banks and the synthesised scratch note all come from the proxy. Plugging
the deck straight into an iPad gives djay the raw deck, which needs a different and
much simpler mapping.
