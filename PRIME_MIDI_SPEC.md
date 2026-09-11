# Denon Prime MIDI Specification

Source: LC6000 PRIME MIDI Specification v1.0 (inMusic, 2020-08-24).
The SC5000M Prime in Computer mode uses the same numbering — verified against
the working djay mapping (play=1, cue=2, shift=26, pads=32–39, jog=CC54/55).

Everything is on **MIDI channel 1** (channel index 0).

## Inbound — device → host

### Buttons — Note On `0x90` / Note Off `0x80`, velocity 127 / 0

| Note | Hex | Control | Note | Hex | Control |
|---|---|---|---|---|---|
| 1  | 0x01 | Play/Pause          | 23 | 0x17 | Slip |
| 2  | 0x02 | Cue                 | 24 | 0x18 | Pitch − |
| 3  | 0x03 | Beat Jump Back      | 25 | 0x19 | Pitch + |
| 4  | 0x04 | Beat Jump Forward   | 26 | 0x1A | **Shift** |
| 5  | 0x05 | Track Skip Previous | 27 | 0x1B | Hot Cue Mode |
| 6  | 0x06 | Track Skip Next     | 28 | 0x1C | Roll Mode |
| 7  | 0x07 | Censor              | 29 | 0x1D | Slicer Mode |
| 8  | 0x08 | Loop In             | 30 | 0x1E | Loop Mode |
| 9  | 0x09 | Loop Out            | 32–39 | 0x20–0x27 | Performance Pads 1–8 |
| 10 | 0x0A | Auto Loop Set (knob press) | 40 | 0x28 | **Platter Touch** |
| 16 | 0x10 | Back                | 68 | 0x44 | Parameter Back |
| 17 | 0x11 | Forward             | 69 | 0x45 | Parameter Forward |
| 18 | 0x12 | Select (knob press) | 70 | 0x46 | Needle Drop (Touch) |
| 19 | 0x13 | Vinyl               |    |      | |
| 20 | 0x14 | Sync                |    |      | |
| 21 | 0x15 | Master Deck         |    |      | |
| 22 | 0x16 | Key Lock            |    |      | |

### Encoders — CC `0xB0`, relative

Forward `1–63` (0x01–0x3F), reverse `127–64` (0x7F–0x40), slow→fast.

| CC | Hex | Control |
|---|---|---|
| 3 | 0x03 | Auto Loop Size (turn) |
| 6 | 0x06 | Select / browse knob (turn) |

### Double-precision — CC `0xB0`, MSB/LSB pair

| Control | Upper CC | Lower CC | Encoding |
|---|---|---|---|
| **Jog Wheel** | 55 (0x37) | 54 (0x36) | relative; fwd 1–63, rev 127–64 |
| Pitch Slider  | 8  (0x08) | 40 (0x28) | absolute 0–127 |
| Needle Drop (scrub) | 64 (0x40) | 64 (0x40) | absolute 0–127 — doc lists the same CC for both bytes; verify on hardware |

## Outbound — host → device (LED feedback)

Same note numbers as the button table above, plus these output-only LEDs:

| Note | Hex | Control |
|---|---|---|
| 18 | 0x12 | Light Ring — Select |
| 19 | 0x13 | Light Ring — Vinyl |
| 41 | 0x29 | Pitch Arrow Back |
| 42 | 0x2A | Pitch Center |
| 43 | 0x2B | Pitch Arrow Forward |

**Single-colour LED state (velocity):** `0` = off, `1` = dim, `2–127` = full brightness.

**RGB LEDs** — pads 32–39 and Platter LED Ring (40) take a colour index as
velocity, per the device colour table (indices roughly 1–64).

Confirmed on the SC5000M: **only** pads 32–39 and the ring take a colour index.
Loop In (8), Loop Out (9) and Auto Loop (10) stay white whatever index they are
sent — `ledtest --hold 8:16,9:40,10:1` lights all three the same. Velocity on
those is brightness, exactly as the table above says.

### The pad colour table — read off the hardware

The table is **not** blocks of one hue, and not a brightness ramp. Indices eight
apart behave completely differently depending on where you start, so the only way
to pick a set is to hold them on the pads and look: `ledtest --colours <list>`.

| Start | Indices | Colours, left to right |
|---|---|---|
| 1 | 1, 9, 17, 25, 33, 41, 49, 57 | red, orange, blue, yellow, green, pink, blue, purple |
| 5 | 5, 13, 21, 29, 37, 45, 53, 61 | blue, aqua, pink, off white, pink, white, pink, white |
| 8 | 8, 16, 24, 32, 40, 48, 56, 64 | green, red, light green, red, yellow, red, yellow, — |

Eight distinct colours, used for the hot cue pads: **1** red, **9** orange,
**17** blue, **25** yellow, **33** green, **41** pink, **13** aqua, **57** purple.
**45** is white, which reads as lit against any of them.

**The screen is not reachable over MIDI at all — see "The 7-inch screen" below.**

## SC5000M-specific — discovered on hardware, absent from the LC6000 spec

The LC6000 spec skips notes 11–15. On the SC5000M those are the top-row buttons,
confirmed by capture (note-on 127 on press, note-off 0 on release, channel 1):

| Note | Hex | Control |
|---|---|---|
| 11 | 0x0B | **LAYER** |
| 12 | 0x0C | SHORTCUT |
| 13 | 0x0D | SOURCE |
| 14 | 0x0E | VIEW |
| 15 | 0x0F | unknown — no corresponding button on this unit |

Note 19, which the LC6000 spec calls "Vinyl", is the **STOP MOTOR** button on the
SC5000M. It behaves as an ordinary momentary button.

**LAYER does emit MIDI in Computer mode.** This contradicts the widely repeated
claim that it is silent; earlier attempts failed because they guessed note 23.
It is a normal momentary button, so it can drive a latching deck switch.

### Platter motor — undocumented, discovered by sweep

The SC5000M's motorised platter is drivable over plain MIDI CC. This appears in no
published Denon specification (the LC6000 has no motor). Confirmed by sweeping every
CC and detecting the rotation the deck reports back.

| CC | Hex | Effect |
|---|---|---|
| 65 | 0x41 | Platter motor **START** — spins forward at fixed speed |
| 66 | 0x42 | Platter motor **STOP** |
| 67 | 0x43 | START (identical effect; likely the layer-B pair) |
| 68 | 0x44 | STOP (identical effect; likely the layer-B pair) |

**The value byte is ignored** — any value, including 0, triggers the command. There is
no speed control and no reverse: values 0 through 127 all produce identical forward
rotation of roughly 750 jog units per second. CC 69 appears to respond only because
the platter is still coasting; with a 3.5 s settle gap it produces nothing.

While the platter turns, the deck streams its rotation back on **CC 17, CC 49, CC 54
and CC 55** in lockstep (equal counts), plus pitch bend:

| Message | Meaning |
|---|---|
| CC 54 | jog delta — `1` = +1 forward, `127` = −1 reverse |
| CC 55 | direction / MSB — `0` forward, `127` reverse |
| CC 17, CC 49 | position counters, incrementing with rotation |
| Pitch bend | 14-bit absolute platter angle, wraps every revolution |

**There is no platter touch sensor.** Note 40 ("Platter Touch" in the LC6000 spec)
is never sent by this deck — verified by resting a hand on a stationary platter with
the motor off and capturing nothing at all. The deck therefore cannot distinguish
motor rotation from a hand, and a host that drives the motor must discard the
rotation it caused or it will seek through the track at roughly 2000 ticks/second.

### Platter resolution and motor speed

Measured by turning the platter through exactly one revolution and counting ticks:

| Quantity | Value |
|---|---|
| Ticks per revolution | **3683** |
| CC 49 wraps per revolution | 28.8 (CC 49 counts 0-127) |
| Position rate under motor | **~2000 ticks/second** |
| Motor speed | **~32.6 RPM — i.e. 33 1/3** |

**The motor speed *can* be read over MIDI — but only from the position counter, never
from message counts.** An earlier reading of ~750 ticks/second was a message rate
mistaken for a tick rate. The deck does not emit one message per tick: it reports
position roughly 450 times a second, and each report advances the counter by one to
four ticks. Counting messages therefore undercounts rotation by about a factor of
four, which is what made 33 1/3 RPM look impossible for USB MIDI to carry.

Measured properly — unwrapping `(CC 17 << 7) | CC 49` and differencing it over a
window — the counter advances ~2000 ticks/s while the motor drives. At 3683 ticks per
revolution that is 0.543 rev/s, or **32.6 RPM**: 33 1/3 within measurement error
(33 1/3 would be 2046 ticks/s). So the motor is not some arbitrary fixed speed, it is
a turntable running at standard vinyl speed.

Measure a rate over a window, not per message. Each report carries one to four whole
ticks over one to four milliseconds, so an instantaneous `d/dt` swings by ±1000
ticks/s on the integer quantum alone.

**The motor has one speed and no direction control.** Values 0-127 on both CC 65 and
CC 67 produce identical forward rotation. Notes do not drive the motor. Matching a
track's tempo is therefore not possible over generic MIDI.

## Other findings

- **Note 56 (0x38)**, velocity 127, repeating every ~300 ms while idle.
  Not an LC6000 control. Appears to be a keepalive / computer-mode heartbeat.
- **LAYER button** — the LC6000 has no layer control. Whether the SC5000M's
  LAYER button emits MIDI in Computer mode is unverified; test with `midimon`.


## The 7-inch screen — a second USB device, not MIDI

An earlier note here claimed the display needed SysEx. That is wrong: the screen is not
on the MIDI interface in any form. In Computer mode the deck presents an internal USB
hub with three separate devices:

| Device | VID:PID | What it is |
|---|---|---|
| SC5000M PRIME Hub | 15e4:e00a | the internal hub |
| SC5000M Prime Controller | 15e4:800a | the MIDI interface everything else here documents |
| **SC5000M PRIME Screen** | **15e4:a00a** | the 7" display, its own USB device |

The screen device carries one vendor-specific interface — class 255, subclass 1, named
**"Denon DJ Remote Screen"** — on USB 2.0 high speed. Four endpoints, read with
`./screenprobe`:

| Endpoint | Direction | Type | Packet | Likely purpose |
|---|---|---|---|---|
| 0x02 | host → device | bulk | 512 B | frame data |
| 0x81 | device → host | bulk | 512 B | readback / acknowledgement |
| 0x04 | host → device | interrupt | 64 B | commands |
| 0x83 | device → host | interrupt | 64 B | touch events (interval 4 ≈ 1 kHz) |

That is the standard shape of a remote display with a touch panel: a fat bulk pipe for
pixels one way, a small interrupt pipe for input the other. Nothing on macOS claims the
interface, so a userspace program can take it.

**The wire format is undocumented and no public reverse-engineering exists.** What the
descriptor does rule out is an uncompressed framebuffer: 1280x720 RGB565 is 1.8 MB per
frame, 55 MB/s at 30 fps, and high-speed bulk tops out near 40 MB/s. So the panel must
take compressed frames — most plausibly one JPEG each. At that size a frame is roughly
100-200 KB, or 3-6 MB/s at 30 fps, which the pipe carries comfortably.

**djay Pro cannot drive it.** Its bundled display drivers are `DenonPrime4WheelDisplay`
(pids 0x9008/0xb008), `DenonLC6000Display` (0xb010) and an MCX8000 pair (0xa002/0xb002),
each bound by USB id through a hidden, control-free stub mapping. There is no SC5000 or
SC6000 display class in the binary at all — djay's Denon SC support is MIDI only.

Next step if this is ever picked up: listen on endpoint 0x83 while touching the screen.
Touch packets are usually easy to decode, and it proves the interface can be claimed
without sending anything.
