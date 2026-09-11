# midiproxy on iOS

Running the SC5000M into djay on an iPad or iPhone with the deck layers, pad banks
and scratch behaviour intact — and no Mac mini in the signal path.

| | |
|---|---|
| Engine portability | high — CoreMIDI + Foundation only |
| Code to rewrite | ~51 call sites, all shallow |
| Hard blocker | 1 unverified unknown (djay iOS custom mappings) |
| Running cost | ~$99/year, Apple Developer account |

## Why the proxy has to come along

Plugging the deck straight into an iPad gives djay the raw SC5000M. That is a usable
controller, but it is not the instrument currently on the desk. Everything below comes
from `midiproxy`, not from the deck and not from the mapping file:

| Capability | How the proxy makes it work | Lost without it |
|---|---|---|
| **Four decks** | LAYER (note 11) is consumed, never forwarded; it cycles a counter that rewrites the MIDI channel so deck N leaves on channel N | 1 deck |
| **Pad banks** | djay re-points its own pads with an internal `modifier2` a mapping file cannot reach. The proxy holds the mode and re-addresses pads to 32–39 / 80–87 / 88–95 / 96–103 | 1 bank |
| **Scratching** | The deck has no touch sensor and never sends note 40. The proxy synthesises it from sustained rotation, so `scratchingMode` engages at all | none |
| **Platter feel** | Unwraps `(CC 17 << 7) | CC 49` to 14-bit, folds 2.4 ticks per step against sensitivity 1.0, releases after 50 ms | untuned |
| **Per-deck LEDs** | Shadows 236 LED outputs per deck and paints only the deck in focus, so four decks do not fight over one set of lamps | crosstalk |
| **Motor** | Drives CC 65/66 from djay's play LED, reading *steadiness* rather than level — djay blinks that lamp at 0.5 s to mean paused | none |

So the question is never "can djay talk to the deck on iOS" — it can, and iOS already
enumerates it. The question is only **where the proxy runs**.

## Port audit

Measured against the current source, 1020 lines. The file is not macOS code needing a
port; it is platform-neutral Swift inside a command-line wrapper.

| What | Count | Disposition |
|---|---|---|
| `import CoreMIDI`, `import Foundation` | 2 | both on iOS |
| CoreMIDI symbols used (17 functions, 3 types) | 20 | cross-platform surface |
| `MIDISourceCreate` / `MIDIDestinationCreateWithBlock` | 2 | virtual endpoints exist on iOS |
| IOKit · AppKit · NSApplication · Process | 0 | nothing to replace |
| `print` / `FileHandle.standardError` | 39 | → in-app log view |
| `exit` / `signal` / signal source | 11 | → app lifecycle |
| `CommandLine.arguments` | 1 | → settings screen |
| Top-level `var` globals | 77 | → wrap in an engine class |

**Caveat.** Those symbols are known to be part of CoreMIDI's cross-platform surface,
but this has **not** been proved by compiling for iOS. Phase 0 exists to turn that
expectation into a fact before anything is built on it.

The 77 globals are the one piece of real refactoring. They work as file-scope state in
a single-purpose CLI process; in an app that starts, stops and restarts they need to
belong to an object that can be torn down and rebuilt. Mechanical, but it touches most
of the file.

## What could sink it

Ordered by what kills the project soonest.

### 1. Custom mappings on djay for iOS — BLOCKER, unverified

On macOS a `.djayMidiMapping` file is dropped into djay's container and selected in the
Devices pane. Whether djay on iOS can load a custom mapping file at all is **unknown**,
and there is no obvious equivalent of that folder.

If it cannot, the project ends here regardless of the proxy — the proxy would publish a
port, but nothing would map its 312 controls. **Test this before writing any code.**

### 2. Three-way CoreMIDI while backgrounded — high, expected to pass

The design needs the deck, the proxy app and djay all holding CoreMIDI at once, with
the proxy alive in the background while djay is foreground. Background MIDI apps do
this routinely, so this should hold — but the whole architecture rests on it, and a
stub app proves it in an afternoon.

### 3. USB power — medium, mitigable

The deck presents an internal USB hub carrying three devices. A powered hub is
required, not optional. Phones are the marginal end of this; the iPad is the sane
target.

**Already passed:** iOS enumerates the deck — `SC5000M Prime Controller Jack 1` appears
over USB on the phone in Computer mode.

### 4. Code signing — cost, not risk

A free Apple ID re-signs every **7 days**, unusable for anything you gig with. A paid
developer account (~$99/yr) holds a build for a year. This is the actual price of
leaving the Mac mini behind; the engineering is the cheap half.

## Plan

Each phase has an exit test. Do not start the next until it passes.

### P0 — prove the two unknowns, no code

Load a custom mapping into djay on iOS by any means available. Separately, compile the
existing `midiproxy.swift` against the iOS SDK and read the errors: that converts the
audit's green rows from expectation into fact.

*Exit: a custom mapping is selectable in djay on iOS, and the engine compiles for iOS
with errors confined to the CLI wrapper.*

### P1 — stub app, pass-through only

An iOS app that creates one virtual source named `SC5000M Proxy` and forwards the deck
untouched. No layers, no pads, no scratch logic. Enable the `audio` background mode.

*Exit: djay lists `SC5000M Proxy`, receives deck messages through it, and keeps
receiving them while the app is backgrounded and djay is foreground.*

### P2 — drop the engine in

Move the engine behind the stub: wrap the 77 globals in a class, replace `print` with a
log buffer the UI can read, replace `exit` paths with error states. No behaviour
changes — close to copy-paste once the state is contained.

*Exit: four decks, pad banks, LEDs and scratching behave as they do on the Mac, judged
by playing on it rather than by logs.*

### P3 — settings and survival

A screen for what the flags cover today — deck count, `--scratch-scale`,
`--scratch-idle`, motor on/off — plus reconnect handling when the deck is power-cycled
mid-set, which the LaunchAgent does now.

*Exit: a full set played from the iPad, deck power-cycled once mid-set without touching
the app.*

## Ruled out

| Option | Why not |
|---|---|
| **Web app** | Two independent blockers. iOS has no Web MIDI in any browser — every iOS browser is WebKit, and Apple has declined it for years over fingerprinting, with no roadmap as of 2026. And Web MIDI cannot create virtual ports on *any* platform: it accesses existing ports, so djay would have nothing to select. |
| **Generic MIDI routers** (Midiflow, MidiBridge) | Static remapping only — channel remap, transpose, velocity curves. Nearly everything here is stateful: a latching deck counter, pad banks that change what notes mean, scratch detection over a time window, 14-bit unwrapping. Wrong tool class. |
| **Scriptable MIDI host** (StreamByter, Mozaic) | Not rejected outright — a genuine fallback if the port stalls. Unevaluated: unclear whether the scripting reaches 14-bit arithmetic and millisecond timing. Worth a look only if P0 or P1 fails. |
| **Small Linux host** (Pi Zero 2 W, USB gadget mode) | Would work and keeps every feature, but replaces one box with another — it does not achieve the goal of carrying less. Reasonable insurance if iOS proves closed. |

## Already settled — do not re-derive

These cost real measurement and are baked into the source defaults. The port inherits
them unchanged.

- `--scratch-scale 2.4` against `rotarySensitivity 1.0`. Sensitivity **multiplies**;
  djay rounds each step to a whole internal unit, so anything below 1.0 rounds away and
  feels lumpy. Gear down in the proxy, never in the mapping.
- `--scratch-idle 0.05`. A real scratch goes still for 1 ms median, 10 ms at p99 —
  0.35 read as the track stopping and restarting.
- `--motor-debounce 0.8`. Must outlast djay's 0.5 s play-LED blink, which is how it
  signals paused.
- Platter: **3683 ticks** per revolution; the motor runs **~2000 ticks/s**, which is
  **33⅓ RPM**.
- Slip must be on for scratching to feel right. Not guessable, and it takes a while to
  work out by hand.
