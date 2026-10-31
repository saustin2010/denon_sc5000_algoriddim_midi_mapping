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
./install_agent.sh       # start the proxy and its prefs page at login, keep them running
```

Then in djay, once: **Preferences → Devices → SC5000M Proxy**, select the mapping.
djay remembers that choice across restarts.

Everything else is on the prefs page, **http://localhost:8750**.

## Preferences

The page edits one file, `~/Library/Application Support/SC5000M Proxy/prefs.json`,
and the proxy re-reads it within half a second of a change. Nothing restarts and
nothing needs re-selecting in djay, so the platter can be retuned while you scratch.

| Pref | Default | |
|---|---|---|
| Decks | **2** | how many decks LAYER cycles; 3 and 4 are there when you want them |
| Touching a playing track | nudges | djay's pitch bend; or scratches; or does nothing |
| Who decides you let go | proxy | the proxy's touch note, or djay's own no-touch handling |
| Let go when the platter coasts | on | a pushed or thrown platter hands the track back to djay |
| Throw boost | on | djay's acceleration curve on the platter |
| Gearing | 2.4 | platter ticks per step; 2.4 is 1:1 vinyl |
| Pickup delay | 50 ms | stillness before the track plays on (proxy touch only) |
| Engage after | 4 | reports in 100 ms before a scratch starts |
| Pitch-bend gearing | 1/8 | platter ticks per tempo-nudge step |
| Send rate to djay | every report | at most one platter message per N ms. Not needed here: djay keeps up at full rate under 60% CPU |
| Motor | off | lets the Vinyl button switch motor mode |

The mapping always binds all four decks, so the deck count is purely the proxy's.
Flags on the `midiproxy` command line still win over the file, applied again after
every reload, so an ad-hoc run from the terminal behaves the way it was asked to.

The page also has a **jog test** (Chrome only; it needs Web MIDI). It reads the deck
and the proxy's output side by side and charts platter speed against what djay is
sent. It counts scratches, drop-outs (a release and re-engage within 250 ms, meaning
the pickup fired under your hand) and pitch-bend messages, which should stay at zero
in scratch mode.

`prefs_server.py` serves it on 127.0.0.1 only. A write has to come from the page
itself: a JSON body with a localhost Host header, which another site open in the
same browser cannot send.

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
> Proxy-side settings need none of this. Everything on the prefs page applies live;
> only the mapping file needs a re-select.

## What the proxy does

**Layers → decks.** LAYER is consumed by the proxy and never reaches djay. It cycles
a counter and rewrites the MIDI channel, so deck N goes out on channel N and the host
sees independent decks. Two by default, up to four (the Decks pref). The platter ring is tinted per deck
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
| Gearing `2.4` | platter ticks folded into one CC step (proxy pref, `--scratch-scale`) |
| `rotarySensitivity 1.0` | djay's multiplier on each step (mapping) |

`rotarySensitivity` **multiplies** — higher is *more* sensitive. Read it off djay's own
mappings: counts-per-revolution × sensitivity is ~1500 on every one of them. Its
SC5000 mapping takes the coarse CC 17 (28.8 counts/rev) at 52.0; its RANE Four takes a
per-tick counter at 0.42, and 52/0.42 is the 128x between them.

Keep sensitivity at or above **1.0**. djay rounds each step to a whole internal unit,
so a step worth 0.42 rounds away two times in three and then lurches — it feels like
coarse, sticky grain, and no amount of tuning fixes it because the problem is the
rounding, not the gearing. Gear down with the proxy instead: 2.4 ticks per step
against sensitivity 1.0 is 1:1 vinyl with every step landing on djay's grid.

**One platter, four bindings.** The mapping carries the platter four ways, and the
proxy sends on exactly one of them, chosen by two prefs. That makes each feel a live
switch rather than a mapping rebuild and a re-select in djay:

| CC | djay target | Release decided by | Acceleration |
|---|---|---|---|
| 49 | `scratchingMove` | proxy (note 40) | 150 |
| 80 | `scratchingMove` | proxy (note 40) | off |
| 81 | `scratchingNoTouchMove` | djay | 150 |
| 82 | `scratchingNoTouchMove` | djay | off |

`scratchingNoTouchMove` is the target djay's own mappings use for platters with no
touch sensor, which this one is (Hercules, Numark DJ2GO and others ship with it). CC 49
is the original and the default. SHIFT always goes out on CC 49, where `jogSeekMove`
sits. Each absolute CC keeps its own running count per deck, so switching between
them never hands djay a stale value to seek from.

**A playing track nudges, a paused one scratches.** Touching a playing track bends its
tempo (djay's `pitchBendMove`) instead of grabbing it, the way the edge of a CDJ jog
works. A paused track scratches as before, whatever the Vinyl button says. Pitch bend
has nothing to act on with the deck stopped: in djay's jog pitch-bend mode, the platter
used to send a stopped track thousands of pitch-bend steps and move it not at all. That
mode is now pinned off. The Vinyl button belongs to the motor, and if djay reports a
deck in pitch-bend mode, the proxy presses djay's toggle to turn it back, because in
that mode djay ignores `scratchingMove` too. SHIFT + platter always seeks. The "Touching a playing track" pref can switch
a playing deck back to scratching, or to ignoring the platter. Each change of play
state is logged as `deck N playing` / `deck N paused`.

The proxy learns play state from djay's `isPlaying`, which the mapping binds as an
output on note 120 for each deck channel: 127 while playing, 0 when stopped, the same
binding the RANE Twelve MKII and Numark Mixdeck Quad mappings ship with. The play LED
is only the fallback, for a djay still holding an older mapping. It signals state by
steadiness (solid for playing, a 0.5 s blink for paused), so it needs 0.8 s to settle,
and on this deck djay once held it lit for over a second straight after a pause. A
paused deck then read as playing, and a scratch turned into a nudge under the hand.

**A coasting platter lets go.** With the motor off, the platter spins free on its
bearing, so a push, a brush or a throw leaves it coasting for seconds. The deck
reports no touch, so all of that used to read as a hand. One brush on a playing track
held it for 6.6 s and dragged it backwards at the coasting speed. A throw ran the track
on for 3.6 s and wound it down to a stop, and the platter rocking as it settled grabbed
it again.

Friction slows a free platter along one curve: it loses rate ÷ 1.11 s + 263 ticks/s²
every second, measured from a 150 rpm throw down to a crawl. A hand doesn't follow that
curve for long. Once the platter has tracked it for 0.10 s, the proxy releases the
scratch and djay plays on. The coast is then ignored until something drives the platter
harder than friction explains: a push, or a hand braking it. Replaying a real session
through the proxy, every coast was caught 0.18–0.26 s after the hand left. A run of
ordinary scratching produced no false calls. Shorter holds or looser tolerances started
catching scratch strokes. Turn it off with the "Let go when the platter coasts" pref.

What no setting can fix: **a hand resting still on the platter is invisible.** With no
touch sensor and no movement, there is nothing to read, so holding the platter does
not stop a playing track. Only motor mode could tell, because the hand would stop a
platter the motor is driving.

**Only the live half of the platter reaches djay.** The deck reports every movement
twice: as a position (CC 17/49) and as a per-report delta (CC 54). Scratch mode uses
the position and pitch-bend mode uses the delta, and the other one is now dropped.
Until 2026-10-31 it was not. The inactive half fell through to the pass-through, so
every scratch also sent djay a stream of `pitchBendMove`. Measured with a scripted
platter, a 1000-tick move sent 1,838 pitch-bend messages alongside the scratch, and
brushes too light to start a scratch still bent a playing track.

**Turn slip on to scratch.** djay's slip mode keeps the track running underneath and
snaps back on release. Without it, scratching drags the playhead and the track has to
pick itself back up. It is the Slip button (note 23) — no menu needed.

**Motor** (`--motor`, off by default; Vinyl toggles it). The motor turns the
platter at 33 1/3 RPM to show a deck is playing, driven from djay's play LED — which
signals state by *steadiness*, not level: solid means playing, a 0.5 s blink means
paused, so `--motor-debounce` must outlast one blink half-period.

Even with `--motor` passed, it starts in **manual** mode. Motor mode costs you
scratching outright, so it has to be asked for. Spin-down ends when the platter stops
reporting rotation rather than after a fixed wait, so the platter frees up as soon as
it has actually stopped.

**Motor mode is a turntable: hold to stop, let go to run.** A hand resting on a free
platter is invisible to this deck, but a hand stopping a platter the motor is driving
is the one thing it can report. So while the motor spins, the proxy compares the
platter with the motor's own speed, measured at 2010 ticks/s (32.7 rpm, 33⅓ to the
deck's accuracy) and steady to ±50 ticks/s.
- **Hand on:** more than 15% off that speed for 15 ms. The proxy raises the touch note
  and the track follows the platter one to one: still under a still hand, scratched by
  a moving one.
- **Let go:** the motor has the platter back at speed in 0.15–0.2 s. Within 8% for
  80 ms hands the track back to djay at the speed it was already playing.
- **Spin-up:** the first 0.4 s after the motor starts is ignored, so pressing play
  doesn't grab the track.

Against a recorded session this caught each hold 60–90 ms after the hand landed. It let
go about 0.2 s after release and never fired on the motor alone. Held, the track plays
at the platter's 33⅓, not at djay's tempo, so a deck pitched up or down changes speed
slightly at the hand-off. Holds go out on CC 80, without acceleration, which would run
the track faster than the platter turns. Pitch bend stays on the PITCH BEND −/+
buttons while the motor runs. `--no-vinyl-hold` restores the older motor mode, which
ignores a spinning platter.

This replaces `--motor-touch`, which tried to subtract a learned motor rate and forward
only the residual. It failed where the residual was ambiguous. Following the whole
platter has no such edge: a hand moving at exactly the motor's speed plays the track
at normal speed either way.

## The controls that are not obvious

Most of the panel does what it says. These do not:

| Control | Does |
|---|---|
| **Vinyl** (note 19) | **motor mode** ↔ manual, with or without SHIFT (needs the Motor pref on). **Lit = motor mode**: hold to stop, let go to run |
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
| `deploy.sh` | build + copy + restart the proxy + tell you to re-select in djay |
| `prefs_server.py` | the prefs page on http://localhost:8750, serving `web/index.html` |
| `midimon.swift` | live MIDI monitor; `-m <mapping>` labels each control with the djay target it hits |
| `ledtest.swift` | walks LEDs and colour indices — use it to pick ring/pad colours |
| `motorhunt.swift` | the CC sweep that found the platter motor |
| `screenprobe.swift` | reads the 7" screen's USB endpoints (see the spec) |
| `install_agent.sh` | LaunchAgents that keep the proxy and the prefs page running across logins and deck power cycles |

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
