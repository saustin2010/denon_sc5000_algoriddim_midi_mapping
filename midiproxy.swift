import CoreMIDI
import Foundation

// ───────────────────────────── options ─────────────────────────────

var hwFilter = "SC5000"
var virtName = "SC5000M Proxy"
var dropSpec = "note:56,cc:55,pitch"
var jogDivisor = 8          // platter ticks per seek step sent to the host
var scratchIdle = 0.05      // stillness before we decide the hand is off. With no
                            // touch sensor this delay IS the pickup: djay holds the
                            // track stopped until it lands, so 0.35 read as the track
                            // stopping and restarting. Measured on a real scratch, the
                            // platter goes still for 1ms median / 10ms at p99 between
                            // moves -- and lastJogAt is stamped on every incoming
                            // report before the dedupe, so slow movement that emits no
                            // CC still counts as a hand on. Only a truly stationary
                            // platter starts the countdown. 0.05 still clears the
                            // measured 10ms p99 by 5x and is what finally made the
                            // pickup feel right; raise toward 0.10 if holding the
                            // platter still mid-scratch drops out of scratch mode.
                            // Must outlast the pause at a scratch turnaround, or
                            // reversing direction drops out of scratch mode and the
                            // track lurches back into normal playback.
var scratchMax = 30.0       // pure safety net; real release comes from going idle
var scratchEnter = 4        // sustained ticks needed to believe a hand is on the platter
var scratchScale = 2.4      // platter ticks per unit handed to the host. The deck
                            // reports 3683 ticks per revolution and CC 49 counts
                            // 0-127, so it wraps 28.8x per turn. Dividing here rounds
                            // to a whole CC step and throws that resolution away — at
                            // 28.8 the finest move you can express is 1/128th of a
                            // turn, which is why an exact spot on the grid is out of
                            // reach. But djay does NOT gear in floating point: it
                            // rounds each step to a whole internal unit, so a step
                            // worth less than 1.0 mostly rounds to nothing and then
                            // lurches when the backlog tips over. So do not pass every
                            // tick -- fold 2.4 of them into one step that djay scales
                            // by exactly 1.0 (build_mapping.py --sensitivity). Same
                            // gearing, every step landing on djay's grid.
var motorDebounce = 0.8     // djay blinks the play LED at 0.5s on/off for paused and
                            // holds it solid for playing, so only a state that outlasts
                            // one blink half-period is real. Must stay above 0.5s or a
                            // blink reads as playing; every extra tenth is lag before
                            // the platter starts, so 0.8 keeps a margin and stays brisk
let enterWindow = 0.10
var verbose = false
var feedback = true
var layerNote = 11          // LAYER on the SC5000M
var layerEnabled = true
var layerLED = true
var layerCount = 2          // decks the LAYER button cycles through (2-4)
// Platter LED ring colour per deck, so the wheel says which deck you are holding.
// Indices are the deck's own colour table (roughly 1-64) — tune by eye with ledtest.
var layerColours = [4, 34, 24, 49]
var motor = false           // opt-in: djay's feedback echoes the button, not play state
var playNote = 1            // djay lights note 1 to signal play state
var playStateNote = 120     // djay's isPlaying, bound by build_mapping.py PLAY_STATE_NOTE
var motorStart = 65
var motorStop  = 66
var jogGate = true
var waitForDeck = false     // sit and wait for the deck rather than exiting
var vinylNote = 19          // Vinyl: the motor button, and its lamp shows motor mode
var shiftNote = 26          // SHIFT. Watched, never consumed: djay binds it as
                            // application.modifier and needs every press.
var shiftHeld = false
// Pad modes. djay re-points its own pads with an internal "modifier2" that only its
// compiled per-device classes can set — a mapping file cannot touch it, so HOT CUE /
// ROLL / SLICER / LOOP would all leave the pads on hot cues. Instead the proxy holds
// the mode itself and re-addresses the pads into a separate note range per mode, so
// the mapping can bind four independent banks of eight.
var padModeEnabled = true
let padModeNotes = [27, 28, 29, 30]          // HOT CUE, ROLL, SLICER, LOOP
let padModeBase  = [32, 80, 88, 96]          // note each bank starts at
let padModeNames = ["hot cue", "roll", "slicer", "auto loop"]
// Two colours per mode: the idle tint says which bank you are on, and the active
// colour says the host has that pad lit — a roll held down, a loop running, a hot
// cue that exists. Without the pair every pad in a bank looks the same, and djay's
// note-off for a finished roll just leaves the pad dark.
// Hot cue idles at 0 — dark. Its eight pads are eight independent slots, so an unlit
// pad has to mean "no cue here"; tinting them all would hide the only thing worth
// reading off the bank. The other three banks are one scale of one thing, where the
// tint says which bank you are on and costs no information.
var padModeColour  = [0, 24, 34, 14]     // idle: the bank's own tint, 0 for dark
var padLitColour   = [45, 45, 45, 45]   // active: white, the one index that reads as
                                        // lit against any of the bank tints
// Hot cues are the one bank whose eight pads mean eight different things, so a cue
// that exists lights in its own colour rather than a shared one — the pads read as a
// map of the track instead of a row of identical lamps. Confirmed on hardware with
// ledtest --colours: 1 blue, 8 green, 9 cyan, 16 red, 17 pink, 24 light green,
// 25 white, 40 yellow. Ordered here to match djay's own cue colours as far as the
// known indices allow — orange and purple are not found yet, so 2 and 8 stand in.
var padCueColours = [16, 24, 1, 40, 8, 17, 9, 25]
let jogCCs: Set<Int> = [17, 49, 54, 55]
var ledFull = true          // buttons at full brightness rather than djay's level
// Pads 32-39 and the platter ring are RGB: velocity is a colour index, not brightness.
// djay sends its own level, so substitute the current bank's colour.
var padColour = true
// Hold to stop, like vinyl. The deck has no touch sensor, so a hand resting on a free
// platter is invisible — but with the motor turning it at 33⅓, a hand that stops it is
// the one thing the deck CAN report. Motor mode therefore holds the track while the
// platter is off the motor's speed and hands it back once the motor has it at speed
// again, so holding, scratching and letting go all work on a spinning platter. Off
// gives the older motor mode, where a spinning platter is ignored entirely.
var vinylHold = true
// These were declared further down until they were moved here, after the option parser
// had already run — so the declaration reset them and --no-led-boost and
// --no-pad-colour were silently ignored. Options live up here.

// Who decides the hand has let go. "touch": the proxy, by raising note 40 while the
// platter moves and dropping it after scratchIdle of stillness — djay's scratchingMove
// under scratchingMode. "notouch": djay, through scratchingNoTouchMove, the target its
// own mappings use for platters with no touch sensor, which this one is.
var scratchEngine = "touch"
var scratchAccel = true     // djay's fast-move curve on the platter (rotaryAcceleration)
var coastRelease = true     // let go when the platter coasts on its own (see coastTau)
// What the platter does to a deck that is playing. "nudge": djay's pitch bend, the
// way the edge of a CDJ jog works — touching a playing track never grabs it. "scratch":
// grab it, as a paused track always is. "ignore": nothing. SHIFT still seeks either way.
var whilePlaying = "nudge"
// Minimum gap between platter messages to djay, in ms; 0 sends on every report. The
// deck reports ~1000 times a second and the proxy passes that straight on, about 20x
// what djay's own SC5000 mapping sees from the same platter. Suspected when fast moves
// made djay lag, and cleared: at the full ~600 msg/s djay stayed under 60% CPU and kept
// up, and the lag was djay's jog pitch-bend mode (see pinScratchMode). Kept as a knob
// for a slower machine; a gap coalesces the steps, which the counter carries losslessly.
var platterGapMs = 0.0

// The settings prefs_server.py edits. Read at start and again whenever the file
// changes, so the platter can be retuned while you scratch on it — no restart, and
// nothing to re-select in djay. Flags on the command line still win: they are applied
// again after every reload, so an ad-hoc run behaves the way it was asked to.
var prefsPath = NSHomeDirectory() + "/Library/Application Support/SC5000M Proxy/prefs.json"

let argv = Array(CommandLine.arguments.dropFirst())
if let i = argv.firstIndex(of: "--prefs"), i + 1 < argv.count { prefsPath = argv[i + 1] }

/// Applies the prefs file over whatever is set now. False if there is no usable file.
@discardableResult
func loadPrefs() -> Bool {
    guard let data = FileManager.default.contents(atPath: prefsPath),
          let p = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
    if let v = p["decks"] as? Int             { layerCount = min(4, max(2, v)) }
    if let v = p["scratchEngine"] as? String, ["touch", "notouch"].contains(v) { scratchEngine = v }
    if let v = p["scratchAccel"] as? Bool     { scratchAccel = v }
    if let v = p["coastRelease"] as? Bool     { coastRelease = v }
    if let v = p["platterGapMs"] as? Double   { platterGapMs = max(0, v) }
    if let v = p["whilePlaying"] as? String, ["nudge", "scratch", "ignore"].contains(v) { whilePlaying = v }
    if let v = p["scratchScale"] as? Double   { scratchScale = max(0.1, v) }
    if let v = p["scratchIdleMs"] as? Double  { scratchIdle = max(1, v) / 1000 }
    if let v = p["scratchEnter"] as? Int      { scratchEnter = max(1, v) }
    if let v = p["jogDivisor"] as? Int        { jogDivisor = max(1, v) }
    if let v = p["motor"] as? Bool            { motor = v }
    return true
}

func parseArgs() {
  var ai = 0
  while ai < argv.count {
    func next() -> String? { ai += 1; return ai < argv.count ? argv[ai] : nil }
    switch argv[ai] {
    case "--prefs":        _ = next()          // read above, before anything else
    case "--scratch-engine": scratchEngine = next() == "notouch" ? "notouch" : "touch"
    case "--no-scratch-accel": scratchAccel = false
    case "--no-coast-release": coastRelease = false
    case "--while-playing":
        let v = next() ?? ""
        if ["nudge", "scratch", "ignore"].contains(v) { whilePlaying = v }
    case "-p", "--port":   hwFilter = next() ?? hwFilter
    case "-n", "--name":   virtName = next() ?? virtName
    case "-d", "--drop":   dropSpec = next() ?? dropSpec
    case "-v", "--verbose": verbose = true
    case "--no-feedback":  feedback = false
    case "--layer-note":   layerNote = Int(next() ?? "") ?? layerNote
    case "--no-layer":     layerEnabled = false
    case "--no-layer-led": layerLED = false
    case "--layers":       layerCount = min(4, max(2, Int(next() ?? "") ?? layerCount))
    case "--layer-colours": layerColours = (next() ?? "").split(separator: ",").compactMap { Int($0) }
    case "--motor":        motor = true
    case "--no-motor":     motor = false
    case "--play-note":    playNote = Int(next() ?? "") ?? playNote
    case "--play-state-note": playStateNote = Int(next() ?? "") ?? playStateNote
    case "--no-jog-gate":  jogGate = false
    case "--no-vinyl-hold":  vinylHold = false
    case "--platter-gap":    platterGapMs = max(0, Double(next() ?? "") ?? platterGapMs)
    case "-w", "--wait":   waitForDeck = true
    case "--vinyl-note":   vinylNote = Int(next() ?? "") ?? vinylNote
    case "--shift-note":   shiftNote = Int(next() ?? "") ?? shiftNote
    case "--no-pad-modes": padModeEnabled = false
    case "--jog-divisor":  jogDivisor = max(1, Int(next() ?? "") ?? jogDivisor)
    case "--scratch-idle": scratchIdle = Double(next() ?? "") ?? scratchIdle
    case "--scratch-max":  scratchMax = Double(next() ?? "") ?? scratchMax
    case "--scratch-enter": scratchEnter = max(1, Int(next() ?? "") ?? scratchEnter)
    case "--scratch-scale": scratchScale = max(0.1, Double(next() ?? "") ?? scratchScale)
    case "--no-led-boost":  ledFull = false
    case "--no-pad-colour": padColour = false
    case "--pad-mode-colours": padModeColour = (next() ?? "").split(separator: ",").compactMap { Int($0) }
    case "--pad-lit-colours": padLitColour = (next() ?? "").split(separator: ",").compactMap { Int($0) }
    case "--pad-cue-colours": padCueColours = (next() ?? "").split(separator: ",").compactMap { Int($0) }
    case "--motor-debounce": motorDebounce = Double(next() ?? "") ?? motorDebounce
    case "-h", "--help":
        print("""
        midiproxy — republish the SC5000M as a clean virtual MIDI port

        Reads the hardware deck, drops the messages you name, and re-emits the rest
        on a virtual port that djay (or anything else) can map. LED/feedback sent
        back to the virtual port is forwarded to the real deck.

        usage: midiproxy [options]
              --prefs <path>  preferences file, re-read whenever it changes
                              (default: ~/Library/Application Support/
                              SC5000M Proxy/prefs.json — edit it from the page
                              prefs_server.py serves). Flags here win over it.
          -p, --port <text>   hardware source to read      (default: SC5000)
          -n, --name <text>   virtual port name            (default: SC5000M Proxy)
          -d, --drop <list>   messages to filter out
                              default: note:56,cc:55,pitch
                              note 56 is the heartbeat; CC 55 and pitch bend
                              duplicate the platter rotation the proxy reads from
                              CC 17/49 and CC 54, and pitch bend is an absolute
                              angle that wraps every revolution — feeding it to a
                              relative jog control makes the host jump wildly.
                              "pitch" drops pitch bend; otherwise note:<n> / cc:<n>
              --no-feedback   do not forward host → device messages

        Layer switching (on by default):
          LAYER latches deck focus: deck N goes out on MIDI channel N, so the host
          sees independent decks and no modifier is involved. LAYER itself is
          consumed by the proxy and never reaches the host.

          LAYER cycles through --layers decks, so the one deck can drive up to four.
          The platter ring is tinted per deck, so the wheel says which one you hold.

              --layers <n>      decks to cycle, 2-4              (default 2)
              --layer-note <n>  button that cycles the deck      (default 11 = LAYER)
              --layer-colours <list>  ring colour index per deck
              --no-layer        disable layer switching entirely
              --no-layer-led    do not light LAYER or tint the ring

        Motorised platter (OFF by default — experimental):
          djay lights the Play button to signal transport state. The proxy reads
          that feedback and spins the platter to match — CC 65 to start, CC 66 to
          stop — but only for the layer you are currently on.

              --motor           drive the platter from djay's play feedback
              --no-motor        leave the platter alone (default)
              --play-note <n>   note djay uses for play state  (default 1)

        Motor mode and the jog gate (on by default):
          The deck reports motor rotation exactly like a hand scratching, and it
          has no touch sensor to tell them apart. So while the motor runs, the
          platter reaches the host only when something takes it off the motor's
          speed: hold it to stop the track, scratch it, let go and the motor runs
          it back up, handing the track back to the host at 33 1/3.

          Vinyl (with or without SHIFT) switches between the two, lit for motor:
            motor mode   platter spins with playback; hold it to stop the track
            manual mode  motor off, platter free, jog and scratching work

              --no-vinyl-hold   motor mode ignores the platter while it spins
              --no-jog-gate     never discard rotation (host will seek on its own)
              --vinyl-note <n>  the motor-mode button, lamp included (default 19)
              --shift-note <n>  SHIFT, watched to qualify it     (default 26)

        Pad modes (on by default):
          HOT CUE / ROLL / SLICER / LOOP re-address the eight pads into their own
          note range — 32-39, 80-87, 88-95, 96-103 — so the mapping can give each
          mode its own eight targets. The mode buttons still reach the host, so
          djay's on-screen pad mode follows along.

          Each bank has two colours: an idle tint that names the bank, and a lit
          colour the pad takes while the host says that pad is active — a roll held
          down, a loop running, a hot cue that exists. An unlit pad falls back to
          the tint rather than going dark.

              --no-pad-modes    pads always send 32-39 whatever the mode
              --pad-mode-colours <list>  idle tint per bank
              --pad-lit-colours <list>   colour per bank while the host lights a pad
              --pad-cue-colours <list>   colour per pad for a hot cue that exists

        Jog sensitivity:
          The platter reports about 250 ticks a second and hosts treat each tick as
          a full seek step, which makes scrubbing far too twitchy. The divisor sums
          ticks and emits one step per N of them.

          Scratching is geared by two numbers that MULTIPLY: --scratch-scale here
          and rotarySensitivity in the mapping (build_mapping.py --sensitivity).
          djay rounds each step to a whole internal unit, so a sensitivity under
          1.0 rounds most steps away and then lurches — keep it at 1.0 or above
          and gear down here instead. 2.4 ticks per step against sensitivity 1.0
          is 1:1 vinyl with every step landing on djay's grid.

              --jog-divisor <n> platter ticks per seek step  (default 8;
                                higher = less sensitive, 1 = raw)
              --scratch-engine touch|notouch
                                who decides the hand has let go: the proxy,
                                through note 40 (default), or djay, through its
                                scratchingNoTouchMove
              --no-scratch-accel  leave djay's acceleration curve off the platter
              --platter-gap <ms>  at most one platter message per <ms> (default 0:
                                every report, ~1000 a second)
              --while-playing nudge|scratch|ignore
                                what the platter does to a playing deck (default
                                nudge: djay's pitch bend; a paused deck scratches)
              --no-coast-release  keep scratching while the platter coasts on its
                                own momentum, as it did before (see coastRelease)
          -w, --wait          wait for the deck instead of exiting when it is
                              absent, and exit if it later goes away — so a
                              supervisor (see the LaunchAgent in the README) can
                              keep a copy running across power cycles
          -v, --verbose       log every message that passes or is dropped

        Point djay at "\(virtName)" and leave the raw deck unmapped.
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(argv[ai])\n".data(using: .utf8)!)
        exit(2)
    }
    ai += 1
  }
}

let prefsFound = loadPrefs()
parseArgs()

// ───────────────────────────── helpers ─────────────────────────────

func strProp(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

struct Filt: Hashable { let isNote: Bool; let d1: Int }
var dropPitch = false

let drops: Set<Filt> = Set(dropSpec.split(separator: ",").compactMap { part in
    if part.trimmingCharacters(in: .whitespaces).lowercased() == "pitch" { dropPitch = true; return nil }
    let b = part.split(separator: ":")
    guard b.count == 2, let n = Int(b[1]) else { return nil }
    switch b[0].lowercased() {
    case "note": return Filt(isNote: true, d1: n)
    case "cc":   return Filt(isNote: false, d1: n)
    default:     return nil
    }
})

/// Splits a raw byte stream into complete MIDI messages, resolving running
/// status and reassembling SysEx that spans packets.
final class Splitter {
    private var status: UInt8 = 0
    private var buf: [UInt8] = []
    private var inSysex = false
    private var sysex: [UInt8] = []
    var onMessage: ([UInt8]) -> Void = { _ in }

    private func expected(_ s: UInt8) -> Int {
        switch s & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch s { case 0xF1, 0xF3: return 1; case 0xF2: return 2; default: return 0 }
        default: return 2
        }
    }

    func feed(_ bytes: [UInt8]) {
        for b in bytes {
            if b >= 0xF8 { onMessage([b]); continue }          // realtime, passes straight through
            if inSysex {
                if b == 0xF7 {
                    inSysex = false; sysex.append(b); onMessage(sysex); sysex = []
                } else if b >= 0x80 {
                    inSysex = false; sysex = []; handleStatus(b)
                } else {
                    sysex.append(b)
                }
                continue
            }
            if b >= 0x80 { handleStatus(b) } else { buf.append(b); tryEmit() }
        }
    }

    private func handleStatus(_ b: UInt8) {
        buf = []
        if b == 0xF0 { inSysex = true; sysex = [b]; status = 0; return }
        status = b
        if expected(b) == 0 { onMessage([b]); status = 0 }
    }

    private func tryEmit() {
        guard status != 0, buf.count == expected(status) else { return }
        onMessage([status] + buf)
        buf = []                                              // keep status for running-status runs
    }
}

func bytes(from pktList: UnsafePointer<MIDIPacketList>) -> [UInt8] {
    var out: [UInt8] = []
    for pkt in pktList.unsafeSequence() {
        withUnsafeBytes(of: pkt.pointee.data) { rb in
            for i in 0..<Int(pkt.pointee.length) { out.append(rb[i]) }
        }
    }
    return out
}

/// Wraps bytes in a MIDIPacketList and hands the pointer to `body`.
func withPacketList(_ msg: [UInt8], _ body: (UnsafePointer<MIDIPacketList>) -> Void) {
    let size = max(1024, msg.count + 128)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { raw.deallocate() }
    let pl = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
    let cur = MIDIPacketListInit(pl)
    _ = MIDIPacketListAdd(pl, size, cur, 0, msg.count, msg)
    body(UnsafePointer(pl))
}

func shouldDrop(_ m: [UInt8]) -> Bool {
    guard let s = m.first else { return false }
    if dropPitch, (s & 0xF0) == 0xE0 { return true }
    guard m.count >= 2 else { return false }
    switch s & 0xF0 {
    case 0x80, 0x90: return drops.contains(Filt(isNote: true,  d1: Int(m[1])))
    case 0xB0:       return drops.contains(Filt(isNote: false, d1: Int(m[1])))
    default:         return false
    }
}

func describe(_ m: [UInt8]) -> String {
    guard let s = m.first else { return "—" }
    let ch = Int(s & 0x0F) + 1
    switch s & 0xF0 {
    case 0x90 where m.count > 2 && m[2] == 0, 0x80: return "ch\(ch) Note Off \(m[1])"
    case 0x90: return "ch\(ch) Note On  \(m[1]) vel \(m.count > 2 ? Int(m[2]) : 0)"
    case 0xB0: return "ch\(ch) CC \(m[1]) = \(m.count > 2 ? Int(m[2]) : 0)"
    case 0xE0: return "ch\(ch) Pitch \(m.count > 2 ? (Int(m[2]) << 7 | Int(m[1])) : 0)"
    case 0xF0: return "SysEx \(m.count) bytes"
    default:   return m.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// ───────────────────────────── layer state ─────────────────────────────

var layer = 0                            // 0-based deck index the deck is driving
var heldNotes = Set<UInt8>()             // notes held down on the current layer
var padMode = 0                          // index into padModeBase
var padHeldMode = [Int](repeating: -1, count: 8)   // mode each pad was pressed in, -1 = up

// The host talks about every deck at once, but the deck has one set of LEDs. Remember
// what the host last said for each deck and each note, show only the deck in focus,
// and repaint from memory on a layer flip. Pads live here too — bank b pad i is note
// padModeBase[b] + i — so a bank switch can restore what the host actually said
// rather than blanket-tinting and then going dark at the first note-off.
var ledShadow = [[UInt8]](repeating: [UInt8](repeating: 0, count: 128), count: 16)
var ledSeen = Set<Int>()                 // notes the host has ever addressed

func isChannelVoice(_ s: UInt8) -> Bool { s >= 0x80 && s < 0xF0 }

/// Rewrites the channel nibble of a channel-voice message to the active layer,
/// so deck N arrives on MIDI channel N and the host sees independent decks.
func onLayer(_ m: [UInt8]) -> [UInt8] {
    guard let st = m.first, isChannelVoice(st) else { return m }
    var out = m
    out[0] = (st & 0xF0) | UInt8(layer & 0x0F)
    return out
}

// ───────────────────────────── wire it up ─────────────────────────────

// The client comes first: CoreMIDI only refreshes its device list for a process that
// has one and pumps its run loop, which is what --wait depends on.
var client = MIDIClientRef()
var deckWentAway = false
guard MIDIClientCreateWithBlock("midiproxy" as CFString, &client, { msg in
    // The deck vanishing (powered off, unplugged) leaves us wired to a dead endpoint.
    // Rather than half-work, exit and let whatever supervises us start a fresh copy —
    // with --wait that one sits waiting for the deck to come back.
    if msg.pointee.messageID == .msgObjectRemoved { deckWentAway = true }
}) == noErr else {
    FileHandle.standardError.write("MIDIClientCreate failed\n".data(using: .utf8)!); exit(1)
}

func findSource() -> MIDIEndpointRef? {
    (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
        .first { strProp($0, kMIDIPropertyDisplayName).localizedCaseInsensitiveContains(hwFilter) }
}

var found = findSource()
if found == nil, waitForDeck {
    print("waiting for a MIDI source matching \"\(hwFilter)\" — power on the deck in Computer mode")
    setvbuf(stdout, nil, _IOLBF, 0)
    while found == nil {
        CFRunLoopRunInMode(.defaultMode, 2.0, false)   // pumping the loop is what lets
        found = findSource()                           // CoreMIDI notice a new device
    }
}
guard let hwSrc = found else {
    FileHandle.standardError.write("no MIDI source matching \"\(hwFilter)\" (use --wait to sit and wait for it)\n".data(using: .utf8)!)
    exit(1)
}
let hwSrcName = strProp(hwSrc, kMIDIPropertyDisplayName)

let hwDests = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
    .filter { strProp($0, kMIDIPropertyDisplayName).localizedCaseInsensitiveContains(hwFilter) }
let hwDst = hwDests.first

// Virtual SOURCE — what djay reads from.
var virtSrc = MIDIEndpointRef()
guard MIDISourceCreate(client, virtName as CFString, &virtSrc) == noErr else {
    FileHandle.standardError.write("could not create virtual source\n".data(using: .utf8)!); exit(1)
}
MIDIObjectSetIntegerProperty(virtSrc, kMIDIPropertyUniqueID, 0x5C50_0001)

let q = DispatchQueue(label: "midiproxy")
var passed = 0, dropped = 0, returned = 0, flips = 0

var outPort = MIDIPortRef()
if hwDst != nil { MIDIOutputPortCreate(client, "midiproxy-out" as CFString, &outPort) }

func toDevice(_ m: [UInt8]) {
    guard let hwDst else { return }
    withPacketList(m) { pl in MIDISend(outPort, hwDst, pl) }
}

var motorRunning = false
// djay's play LED, per deck. It does not signal play state by level: it holds the LED
// solid to mean playing and BLINKS it at 0.5s on/off to mean paused, so "lit" alone is
// true half the time in both states. Lit and unchanged for motorDebounce is the only
// reading that means playing. Every deck is followed, not just the one in focus, so a
// layer flip lands on the right answer at once.
var playLit = [Bool](repeating: false, count: 16)
var playLitSince = [Date](repeating: .distantPast, count: 16)
var deckPlays = [Bool](repeating: false, count: 16)
// The play LED is only the fallback. Read live, it was not even reliable: straight after
// one pause djay held it lit for over a second, so a paused deck read as playing and a
// scratch turned into a nudge under the hand. A mapping that carries djay's isPlaying
// (build_mapping.py binds it to playStateNote) says it outright, with no debounce — once
// a deck has reported that way, its LED is no longer consulted.
var playReported = [Bool?](repeating: nil, count: 16)

enum PlatterRole { case scratch, bend, none }
/// Which djay control the platter drives right now. Exactly one, or none: djay acts
/// on every target that matches, so a platter on two of them does both at once.
func platterRole() -> PlatterRole {
    if shiftHeld { return .scratch }                 // jogSeekMove, playing or not
    // A stopped track scratches. Pitch bend has nothing to bend on a stopped deck: with
    // djay in its jog pitch-bend mode, moving the platter sent 2,828 pitch-bend steps and
    // the track did not move at all. That mode is pinned off now (see pinScratchMode).
    guard deckPlays[layer] else { return .scratch }
    switch whilePlaying {
    case "nudge":   return .bend
    case "scratch": return .scratch
    default:        return .none
    }
}
var motorMode = false           // start in manual: the platter is the instrument, and
                                // motor mode costs you scratching outright, so it has
                                // to be asked for. Starting motor-side also made the
                                // first SHIFT+Vinyl press look like it did nothing —
                                // it was turning the feature off, not on.
var lastRotationAt = Date.distantPast
var playing = false
var jogSuppressed = 0
var jogAccum = 0            // leftover platter ticks below the divisor threshold

// The deck has no touch sensor, but with the motor off any platter movement is a
// hand. Synthesise the scratch-mode note from motion so the host can scratch.
var scratching = false
var lastJogAt = Date.distantPast
var recentTicks: [Date] = []
var coarse = 0              // CC 17 — high 7 bits of platter position
var lastPos = -1            // last combined 14-bit position
let posCoarseCC = 17
var virtualPos = 0.0        // scaled position handed to the host
var scratchStartedAt = Date.distantPast
let posCC = 49              // absolute platter position
let scratchNote = 40        // "Platter Touch" — unused by this deck, free to reuse
let platterRingNote = 40    // same note outbound to the device: the ring's RGB colour

func emitToHost(_ m: [UInt8]) {
    let routed = layerEnabled ? onLayer(m) : m
    withPacketList(routed) { pl in MIDIReceived(virtSrc, pl) }
}

func setScratching(_ on: Bool) {
    guard on != scratching else { return }
    if !on { sendPlatter(force: true) }  // steps still held back by the gap go first
    scratching = on
    if on { scratchStartedAt = Date() }
    // With djay deciding the release, the note is never raised: scratchingMode would
    // hold the track the way a hand does, which is exactly the call being left to djay.
    // The state is still kept, because it is what filters stray ticks on the way in.
    // A motor hold always uses the note: holding the track still is the whole point.
    if scratchEngine == "touch" || motorRunning { emitToHost([0x90, UInt8(scratchNote), on ? 127 : 0]) }
    if verbose { print("  scratch \(on ? "start" : "end")") }
}

// The platter goes out on one of four CCs. The mapping binds the same platter four
// ways, so trying another feel is a preference rather than a mapping reload in djay:
//   49  scratchingMove,        touch from note 40, acceleration    (the original)
//   80  scratchingMove,        touch from note 40, no acceleration
//   81  scratchingNoTouchMove, djay decides release, acceleration
//   82  scratchingNoTouchMove, djay decides release, no acceleration
// Only one ever moves. SHIFT always takes CC 49, where jogSeekMove lives.
func platterOut() -> (cc: Int, absolute: Bool) {
    if shiftHeld { return (posCC, true) }
    // Under a motor hold the track follows the platter one to one: acceleration would
    // run it faster than the platter turns, and the hand-off at 33⅓ would jump.
    if motorRunning { return (80, true) }
    switch (scratchEngine == "notouch", scratchAccel) {
    case (false, true):  return (49, true)
    case (false, false): return (80, true)
    case (true, true):   return (81, false)
    case (true, false):  return (82, false)
    }
}
var sentSteps = 0                   // whole steps of virtualPos already handed to djay
// djay reads an absolute CC as the difference from the last value it saw on that CC,
// per channel. Each one therefore keeps its own count, advanced only by what is sent
// on it, so moving between CCs or decks never lands djay on a stale value and seeks.
var absSent = [Int: Int]()          // channel * 128 + cc -> last value sent

var platterSentAt = 0.0
/// Hands djay whatever whole steps virtualPos has gained since the last message — at
/// most one message per platterGapMs. Steps held back by the gap go out with the next
/// report, before any release, or from the idle timer if the platter stops reporting.
func sendPlatter(force: Bool = false) {
    let now = CFAbsoluteTimeGetCurrent()
    if !force, platterGapMs > 0, now - platterSentAt < platterGapMs / 1000 { return }
    // A 7-bit step can only say ±63; anything bigger waits for the next report.
    let n = max(-63, min(63, Int(virtualPos.rounded()) - sentSteps))
    guard n != 0 else { return }
    sentSteps += n
    let (cc, absolute) = platterOut()
    let v: Int
    if absolute {
        let key = layer * 128 + cc
        v = ((absSent[key, default: 0] + n) % 128 + 128) % 128
        absSent[key] = v
    } else {
        v = n > 0 ? n : 128 + n     // djay's "rotary": 1-63 forward, 127-65 back
    }
    platterSentAt = now
    passed += 1
    if verbose { print("  pass  ch\(layer + 1) CC \(cc) = \(v)  (\(n > 0 ? "+" : "")\(n), scaled 1/\(scratchScale))") }
    emitToHost([0xB0, UInt8(cc), UInt8(v)])
}
// ── A platter turning on its own ──
// With the motor off this platter spins free on its bearing. A push, a brush or a
// throw leaves it coasting for seconds, and since the deck reports no touch, all of it
// used to read as a hand: one brush on a playing track held it for 6.6s, dragged
// backwards at whatever speed the platter happened to coast, and a throw ran the track
// on for 3.6s and wound it down to a stop.
//
// A coasting platter is easy to recognise, though, because friction slows it along
// one curve. Measured off this deck (capture 2026-10-31): it loses rate/1.11s + 263
// ticks/s² every second, the same curve from a 150 rpm throw down to a crawl. A hand
// does not follow that for long. So once the platter has tracked the curve for
// coastHold, the hand is off: the scratch is let go, djay plays the track on, and the
// coast is ignored until something drives the platter again — faster than a coast
// can go, or braking harder than friction can.
//
// Replayed against the capture, every coast was caught 0.18-0.26s after the hand left
// and nothing in a run of real scratching was mistaken for one. Shorter holds or
// looser tolerances started catching scratch strokes, so these are the fastest
// settings that held at zero.
let coastTau = 1.11, coastDrag = 263.0      // measured: decel = rate/tau + drag
let coastTolRel = 0.06, coastTolAbs = 60.0  // how closely the platter must follow it
let coastHold = 0.10                        // ... and for how long
let coastMinRate = 400.0                    // ticks/s; slower than this, too coarse to judge
let coastQuiet = 0.5                        // stillness that ends a coast, settling included
let coastRateWin = 0.05, coastRateGap = 0.10
var freeCoast = false
var coastStartedAt = 0.0
var coastLikeSince: Double? = nil
var coastPos = 0                            // unwrapped platter position, always tracked
var coastLastRaw = -1
var coastHist: [(t: Double, pos: Int)] = []

func wrap14(_ d: Int) -> Int { d > 8192 ? d - 16384 : d < -8192 ? d + 16384 : d }

/// Position as of `t`: the last report at or before it.
func coastPosAt(_ t: Double) -> Int {
    for e in coastHist.reversed() where e.t <= t { return e.pos }
    return coastHist.first?.pos ?? 0
}
/// Ticks per second over the window ending at `t`. Always over a window: one report
/// carries 1-8 whole ticks, far too coarse for a per-message rate.
func coastRate(_ t: Double) -> Double {
    Double(coastPosAt(t) - coastPosAt(t - coastRateWin - 1e-9)) / coastRateWin
}
/// Where friction alone takes a platter turning at `r0` after `dt`.
func coastPredict(_ r0: Double, _ dt: Double) -> Double {
    let v = (abs(r0) + coastDrag * coastTau) * exp(-dt / coastTau) - coastDrag * coastTau
    return (r0 < 0 ? -1 : 1) * max(v, 0)
}
func coastTolerance(_ r0: Double) -> Double { coastTolRel * abs(r0) + coastTolAbs }

/// True once the platter has followed the friction curve for coastHold.
func coastsFreely(at t: Double) -> Bool {
    let now = coastRate(t), before = coastRate(t - coastRateGap)
    let like = abs(before) >= coastMinRate && now * before > 0 && abs(now) < abs(before)
        && abs(now - coastPredict(before, coastRateGap)) <= coastTolerance(before)
    guard like else { coastLikeSince = nil; return false }
    if coastLikeSince == nil { coastLikeSince = t }
    return t - coastLikeSince! >= coastHold
}
/// True when something other than friction is moving a coasting platter.
func handBack(at t: Double) -> Bool {
    let now = coastRate(t), before = coastRate(t - coastRateGap)
    guard abs(now) >= 150 || abs(before) >= 150, t - coastStartedAt > 0.05 else { return false }
    let off = abs(now - coastPredict(before, coastRateGap)) > 2 * coastTolerance(before)
    return off || (now * before < 0 && abs(now) > 150)
}

var motorStoppedAt = Date.distantPast
let coastWindow = 4.0       // platter keeps turning after a stop command

var motorSettleUntil = Date.distantPast
// djay reports its own jog mode by lighting note 19: LIT means pitch bend, dark means
// scratch. Read it back so the platter only ever drives the control that is actually
// live — both were bound at once (scratchingMove on CC 49, pitchBendMove on CC 54) and
// a host that acts on both scratches and nudges tempo off one hand movement.
var bendMode = [Bool](repeating: false, count: 16)

// ── Hold to stop, on a driven platter ──
// Measured off this deck (capture 2026-10-31, motor mode, three holds): the motor turns
// the platter at 2010 ticks/s — 32.7 rpm, 33⅓ to the deck's own accuracy — steady to
// ±50 ticks/s at p99 over a 50ms window. A hand stops it within 0.2s, and on release the
// motor has it back at speed in 0.15-0.2s. Replayed against that capture, these caught
// each hold 60-90ms after the hand landed, let go ~0.2s after release, and never fired
// on the motor alone. The rate is the coast tracker's, over the same 50ms window.
let motorRate = 2010.0
let holdEnterFrac = 0.15, holdEnterTime = 0.015    // this far off speed, this long: a hand
let holdExitFrac = 0.08, holdExitTime = 0.08       // back within this, this long: let go
var holdOffSince: Double? = nil
var holdAtSpeedSince: Double? = nil

/// Rotation reports: the documented jog pair, the two undocumented twins, and pitch bend.
func isJogReport(_ m: [UInt8]) -> Bool {
    guard let st = m.first else { return false }
    if (st & 0xF0) == 0xE0 { return true }
    if (st & 0xF0) == 0xB0, m.count >= 2 { return jogCCs.contains(Int(m[1])) }
    return false
}

func setMotor(_ on: Bool) {
    guard motor, on != motorRunning else { return }
    if !on { setScratching(false) }     // while motorRunning still says who raised it
    motorRunning = on
    if !on { motorStoppedAt = Date() }
    // Spin-up runs through every speed between rest and 33⅓, which is exactly what a
    // hand looks like. Measured, the platter is at speed 0.15-0.25s after the start
    // command, so the hold waits that out rather than grabbing the track on every play.
    motorSettleUntil = Date().addingTimeInterval(on ? 0.4 : 0)
    holdOffSince = nil
    holdAtSpeedSince = nil
    toDevice([0xB0, UInt8(on ? motorStart : motorStop), 0])
    if verbose { print("  motor \(on ? "start" : "stop")") }
}

/// Sends one remembered LED state to the deck. Pads carry a colour index rather than
/// a brightness, so an unlit pad becomes the bank's idle tint instead of going dark —
/// otherwise a momentary target like a roll blacks its pad out on release and nothing
/// ever lights it again.
func paintNote(_ n: Int, _ v: UInt8) {
    if padModeEnabled, let bank = padModeBase.firstIndex(where: { ($0...($0 + 7)).contains(n) }) {
        guard bank == padMode else { return }        // stale bank: remembered, not on screen
        let i = n - padModeBase[bank]
        let lit = bank == 0 && i < padCueColours.count ? padCueColours[i] : padLitColour[bank]
        let vel = padColour ? UInt8((v > 0 ? lit : padModeColour[bank]) & 0x7F) : v
        if verbose { print("  pad   \(padModeNames[bank]) \(i + 1) -> colour \(vel)  (host said \(v))") }
        toDevice([0x90, UInt8(32 + i), vel])
        return
    }
    // Everything outside the pads and the platter ring is a single-colour LED, where
    // velocity is brightness — confirmed on the loop group, which stays white however
    // it is addressed. Only the two RGB controls take a colour index.
    toDevice([0x90, UInt8(n), ledFull && v > 0 ? 127 : v])
}

/// Lights the active mode button and repaints the eight pads for the new bank.
func showPadMode() {
    guard padModeEnabled else { return }
    for (i, n) in padModeNotes.enumerated() {
        toDevice([0x90, UInt8(n), i == padMode ? 127 : 0])
    }
    guard padColour else { return }
    for i in 0..<8 { paintNote(padModeBase[padMode] + i, ledShadow[layer][padModeBase[padMode] + i]) }
}

/// Repaints every LED the host has ever addressed from the focused deck's memory.
func showDeckLEDs() {
    for n in ledSeen where !(padModeEnabled && padModeBase.contains(where: { ($0...($0 + 7)).contains(n) })) {
        paintNote(n, ledShadow[layer][n])
    }
    showPadMode()
}

/// The Vinyl lamp is the motor's: lit while motor mode is on.
func showVinyl() { toDevice([0x90, UInt8(vinylNote), motor && motorMode ? 127 : 0]) }

var pinnedAt = [Date](repeating: .distantPast, count: 16)
/// Turns djay's jog pitch-bend mode back off for a deck, by pressing its toggle on the
/// proxy's side. In that mode djay ignores scratchingMove, so a deck left in it — from
/// djay's own settings, or a Vinyl press before the button became the motor's — cannot
/// scratch at all. At most once a second per deck, so a stale echo cannot loop.
func pinScratchMode(_ ch: Int) {
    guard Date().timeIntervalSince(pinnedAt[ch]) > 1.0 else { return }
    pinnedAt[ch] = Date()
    for v: UInt8 in [127, 0] {
        withPacketList([0x90 | UInt8(ch & 0x0F), UInt8(vinylNote), v]) { pl in MIDIReceived(virtSrc, pl) }
    }
    print("  deck \(ch + 1): djay was in jog pitch-bend mode — switched it back to scratch")
}

/// Lights LAYER off deck 1, and tints the platter ring to the current deck's colour.
func showLayer() {
    showVinyl()
    guard layerLED else { return }
    toDevice([0x90, UInt8(layerNote), layer == 0 ? 0 : 127])
    if !layerColours.isEmpty {
        let c = layerColours[layer % layerColours.count]
        toDevice([0x90, UInt8(platterRingNote), UInt8(c & 0x7F)])
    }
}

func switchLayer(to next: Int) {
    // release anything still held, on the layer it was pressed on — a scratch included
    setScratching(false)
    for n in heldNotes {
        withPacketList(onLayer([0x90, n, 0])) { pl in MIDIReceived(virtSrc, pl) }
    }
    heldNotes.removeAll()
    padHeldMode = [Int](repeating: -1, count: 8)   // those releases are now sent
    layer = next
    flips += 1
    showLayer()
    showDeckLEDs()          // the new deck's LEDs, as the host last described them
    print("  layer \(Character(UnicodeScalar(65 + layer)!)) — deck \(layer + 1) (channel \(layer + 1))")
}

func prefsSummary() -> String {
    "decks \(layerCount), \(scratchEngine == "touch" ? "proxy touch" : "djay no-touch")"
    + "\(scratchAccel ? " + acceleration" : ", no acceleration")"
    + "\(coastRelease ? ", lets go on a coast" : ", scratches through a coast")"
    + "\(platterGapMs > 0 ? ", platter every \(Int(platterGapMs))ms" : "")"
    + ", playing deck \(whilePlaying == "nudge" ? "nudges" : whilePlaying == "scratch" ? "scratches" : "ignores the platter"), scale 1/\(scratchScale), "
    + "release \(Int((scratchIdle * 1000).rounded()))ms, engage \(scratchEnter), "
    + "bend 1/\(jogDivisor), motor \(motor ? "available" : "off")"
}

func prefsStamp() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: prefsPath))?[.modificationDate] as? Date
}
var lastPrefsStamp = prefsStamp()

/// Picks up an edited prefs file while running. Everything it carries is safe to change
/// live, with three things to put right first: a scratch in progress is let go (the
/// engine that raised note 40 may be about to change), a deck that no longer exists is
/// left for deck 1, and a motor that is no longer allowed is stopped.
func reloadPrefs() {
    setScratching(false)
    guard loadPrefs() else { return }
    parseArgs()                         // the command line still wins
    if layer >= layerCount { switchLayer(to: 0) }
    if !motor {
        if motorRunning { motorRunning = false; motorStoppedAt = Date(); toDevice([0xB0, UInt8(motorStop), 0]) }
        motorMode = false
    }
    showVinyl()
    print("prefs: \(prefsSummary())")
}

// device → filter → virtual source
let inSplitter = Splitter()
inSplitter.onMessage = { m in
    if shouldDrop(m) {
        dropped += 1
        if verbose { print("  drop  \(describe(m))") }
        return
    }

    // SHIFT is watched but never swallowed — djay binds it too.
    if m.count >= 3, Int(m[1]) == shiftNote, (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
        shiftHeld = (m[0] & 0xF0) == 0x90 && m[2] > 0
    }

    // Vinyl is the motor button. Every press, SHIFT or not, switches the platter between
    // a turntable (spinning with playback, hold it to stop the track) and a free one,
    // and its lamp says which. It never reaches djay: djay's own use of it, jog pitch-
    // bend mode, is not wanted any more. The proxy chooses scratch or nudge from play
    // state, and in that mode djay ignores scratchingMove, so the platter goes dead.
    if m.count >= 3, Int(m[1]) == vinylNote, (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
        if (m[0] & 0xF0) == 0x90 && m[2] > 0 {
            if motor {
                motorMode.toggle()
                playing = deckPlays[layer]
                setMotor(motorMode && playing)
                print(motorMode ? (vinylHold ? "  motor mode — platter spins with playback; hold it to stop the track"
                                             : "  motor mode — platter spins with playback, jog ignored")
                                : "  manual mode — motor off, platter free to scratch")
            } else {
                print("  Vinyl — motor mode is switched off on the prefs page")
            }
            showVinyl()
        }
        return
    }

    // With no touch sensor, rotation while the motor drives is never scratching --
    // unless we are subtracting the motor's own rate, in which case the CC 49 handler
    // sorts hand from motor and the other rotation reports are duplicates we drop.
    //
    // Spin-down is still the motor's rotation, but how long it runs is a property of
    // the platter, not a constant — waiting out a fixed window meant the platter
    // stayed dead for seconds after it had visibly stopped. Watch for the reports to
    // actually cease instead, and keep the window only as a backstop. The gap is
    // measured BEFORE this report is counted, so the first touch after a real stop
    // reads as a hand rather than as more coasting.
    let rotationGap = Date().timeIntervalSince(lastRotationAt)
    if isJogReport(m) { lastRotationAt = Date() }
    let coasting = Date().timeIntervalSince(motorStoppedAt) < coastWindow
                   && rotationGap < 0.2
    let driven = motor && (motorRunning || coasting)
    if jogGate, driven, isJogReport(m) {
        let isCC  = m.count >= 3 && (m[0] & 0xF0) == 0xB0
        // Position feeds the hand-or-motor decision, so it always gets through.
        let isPos = isCC && (Int(m[1]) == posCC || Int(m[1]) == posCoarseCC)
        // The jog delta drives pitch bend, which moves TEMPO and accumulates -- so a
        // touch call that is briefly wrong leaves the track permanently off speed,
        // where the same mistake on the scratch path is just a nudge in position that
        // the next moment corrects. It is not worth that risk on a driven platter:
        // pitch bend stays on the PITCH BEND -/+ buttons while the motor runs. Spin-up
        // and spin-down are the motor's too, so only a platter at speed gets through.
        if !(vinylHold && motorRunning && Date() >= motorSettleUntil && isPos) {
            jogSuppressed += 1
            return
        }
    }

    // LAYER is consumed here: it toggles deck focus and never reaches the host.
    if layerEnabled, m.count >= 3, Int(m[1]) == layerNote,
       (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
        let isPress = (m[0] & 0xF0) == 0x90 && m[2] > 0
        if isPress { switchLayer(to: (layer + 1) % layerCount) }
        return
    }

    // Pad mode buttons pick which bank the pads address. They still reach the host
    // afterwards, so djay's own pad-mode display keeps up.
    if padModeEnabled, m.count >= 3, (m[0] & 0xF0) == 0x90, m[2] > 0,
       let mode = padModeNotes.firstIndex(of: Int(m[1])), mode != padMode {
        // a pad still down belongs to the bank it was pressed in
        for i in 0..<8 where padHeldMode[i] >= 0 {
            emitToHost([0x90, UInt8(padModeBase[padHeldMode[i]] + i), 0])
            padHeldMode[i] = -1
        }
        padMode = mode
        showPadMode()
        print("  pads — \(padModeNames[mode]) (notes \(padModeBase[mode])-\(padModeBase[mode] + 7))")
    }

    // Re-address a pad into the current bank. Note-off follows the bank the pad was
    // pressed in, so switching mode mid-hold cannot strand a note-on.
    if padModeEnabled, m.count >= 3, (0x80...0x9F).contains(m[0]),
       (32...39).contains(Int(m[1])) {
        let i = Int(m[1]) - 32
        let down = (m[0] & 0xF0) == 0x90 && m[2] > 0
        let bank = down ? padMode : (padHeldMode[i] >= 0 ? padHeldMode[i] : padMode)
        padHeldMode[i] = down ? padMode : -1
        var out = m
        out[1] = UInt8(padModeBase[bank] + i)
        // Pads return early, so they have to join heldNotes here or a layer flip
        // mid-hold never releases them — under their bank address, which is what the
        // host was actually told about.
        if down { heldNotes.insert(out[1]) } else { heldNotes.remove(out[1]) }
        passed += 1
        if verbose { print("  pass  \(describe(layerEnabled ? onLayer(out) : out))  (\(padModeNames[bank]) pad \(i + 1))") }
        emitToHost(out)
        return
    }

    // track held notes so a mid-hold layer flip cannot strand a note-on
    if m.count >= 3 {
        if (m[0] & 0xF0) == 0x90 && m[2] > 0 { heldNotes.insert(m[1]) }
        if (m[0] & 0xF0) == 0x80 || ((m[0] & 0xF0) == 0x90 && m[2] == 0) { heldNotes.remove(m[1]) }
    }

    // CC 17 is the high half of the platter position. Held locally, never forwarded.
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, Int(m[1]) == posCoarseCC {
        coarse = Int(m[2])
        return
    }

    // Absolute platter position. A settling platter emits stray single ticks, and
    // acting on those makes the host lurch back into scratching — so require
    // sustained movement before believing a hand is on the platter, and forward
    // position only while we do.
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, Int(m[1]) == posCC {
        let now = Date()
        lastJogAt = now
        // CC 49 wraps several times per revolution; unwrap it, scale it down, and
        // hand the host a position that moves at a sane rate.
        let raw = (coarse << 7) | Int(m[2])

        let t = now.timeIntervalSinceReferenceDate
        // After a pause — pitch-bend mode, a held platter — the last position is stale,
        // and differencing against it would read as one enormous jump.
        if let last = coastHist.last, t - last.t > 0.3 { coastLastRaw = -1 }
        if coastLastRaw >= 0 { coastPos += wrap14(raw - coastLastRaw) }
        coastLastRaw = raw
        coastHist.append((t, coastPos))
        while let first = coastHist.first, t - first.t > 0.3 { coastHist.removeFirst() }

        if motorRunning, vinylHold {
            // The motor turns the platter; a hand is whatever takes it off that speed.
            // Held, the track follows the platter exactly — stopped under a still hand,
            // scratched by a moving one, and run back up with the motor on release, so
            // the hand-off at 33⅓ lands djay at the speed it was already playing.
            let off = abs(coastRate(t) - motorRate)
            if !scratching {
                // The gate holds reports back through spin-up, so the history starts
                // empty when it ends; a rate over less than a full window reads low and
                // looked like a hand — a 0.11s grab on every play, before this.
                guard let first = coastHist.first, t - first.t >= coastRateWin else { return }
                holdOffSince = off > motorRate * holdEnterFrac ? (holdOffSince ?? t) : nil
                guard let since = holdOffSince, t - since >= holdEnterTime else { return }
                holdOffSince = nil
                holdAtSpeedSince = nil
                lastPos = -1
                if verbose { print("  hold — hand on a spinning platter") }
                setScratching(true)
            } else if off < motorRate * holdExitFrac {
                holdAtSpeedSince = holdAtSpeedSince ?? t
                if t - holdAtSpeedSince! >= holdExitTime {
                    holdAtSpeedSince = nil
                    if verbose { print("  hold — let go, platter back at speed") }
                    setScratching(false)
                    return
                }
            } else {
                holdAtSpeedSince = nil
            }
            if lastPos >= 0 { virtualPos += Double(wrap14(raw - lastPos)) / scratchScale }
            lastPos = raw
        } else {

            // Coasting is told apart in every role. A nudge needs it as much as a
            // scratch does: one brush on a playing track would otherwise bend its
            // tempo for as long as the platter took to stop.
            let role = platterRole()
            if freeCoast {
                // The platter is turning on its own momentum and djay has the track
                // back. Keep out of its way until a hand drives the platter again.
                guard handBack(at: t) else { return }
                freeCoast = false
                if verbose { print("  coast — hand back on") }
                if role == .scratch { lastPos = -1; setScratching(true) }
            } else if coastRelease, role != .scratch, coastsFreely(at: t) {
                freeCoast = true
                coastStartedAt = t
                coastLikeSince = nil
                if verbose { print("  coast — platter turning on its own") }
                return
            }
            guard role == .scratch else {
                setScratching(false)
                return                       // CC 54 carries the platter, or nothing does
            }
            if !scratching {
                recentTicks.append(now)
                recentTicks.removeAll { now.timeIntervalSince($0) > enterWindow }
                guard recentTicks.count >= scratchEnter else {
                    jogSuppressed += 1
                    return                   // stray tick: never reaches the host
                }
                recentTicks.removeAll()
                lastPos = -1
                coastLikeSince = nil
                setScratching(true)
            }
            if coastRelease, coastsFreely(at: t) {
                freeCoast = true
                coastStartedAt = t
                coastLikeSince = nil
                if verbose { print("  coast — hand off, platter turning on its own") }
                setScratching(false)
                return
            }
            if lastPos >= 0 {
                var d = raw - lastPos
                if d >  8192 { d -= 16384 }
                if d < -8192 { d += 16384 }
                virtualPos += Double(d) / scratchScale
            }
            lastPos = raw
        }
        sendPlatter()
        return
    }

    // Scale the platter down: accumulate ticks, emit one step per `jogDivisor`.
    // Only in the bend role — Vinyl dark, or a playing deck — otherwise the platter
    // drives scratchingMove and pitchBendMove off the same movement at once. CC 54
    // carries the report's tick count (1-8 forward, 127-120 back), so this is ticks.
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, Int(m[1]) == 54, platterRole() == .bend {
        guard !freeCoast else { dropped += 1; return }
        let v = Int(m[2])
        jogAccum += v >= 64 ? v - 128 : v
        while abs(jogAccum) >= jogDivisor {
            let fwd = jogAccum > 0
            jogAccum -= fwd ? jogDivisor : -jogDivisor
            let step: [UInt8] = [m[0], m[1], fwd ? 1 : 127]
            let routed = layerEnabled ? onLayer(step) : step
            passed += 1
            if verbose { print("  pass  \(describe(routed))  (scaled 1/\(jogDivisor))") }
            withPacketList(routed) { pl in MIDIReceived(virtSrc, pl) }
        }
        return
    }

    // Whichever half of the platter is not live goes nowhere. Gating the two handlers
    // above on bendMode was not enough on its own: the inactive half fell through to
    // the pass-through below, so in scratch mode raw CC 54 reached pitchBendMove on
    // every tick — the platter nudged tempo while it scratched, and a brush too light
    // to start a scratch still bent a playing track.
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, jogCCs.contains(Int(m[1])) {
        dropped += 1
        return
    }

    let routed = layerEnabled ? onLayer(m) : m
    passed += 1
    if verbose { print("  pass  \(describe(routed))") }
    withPacketList(routed) { pl in MIDIReceived(virtSrc, pl) }
}

var inPort = MIDIPortRef()
guard MIDIInputPortCreateWithBlock(client, "midiproxy-in" as CFString, &inPort, { pktList, _ in
    let b = bytes(from: pktList)
    q.async { inSplitter.feed(b) }
}) == noErr, MIDIPortConnectSource(inPort, hwSrc, nil) == noErr else {
    FileHandle.standardError.write("could not connect to \"\(hwSrcName)\"\n".data(using: .utf8)!); exit(1)
}

// Virtual DESTINATION — what djay writes to (LED feedback), forwarded to the deck.
var virtDst = MIDIEndpointRef()
if feedback, hwDst != nil {
    let outSplitter = Splitter()
    outSplitter.onMessage = { m in
        returned += 1
        if verbose { print("  led   \(describe(m))") }

        // djay's isPlaying: consumed here, never shown — the deck has no such lamp.
        if m.count >= 3, Int(m[1]) == playStateNote, (0x80...0x9F).contains(m[0]) {
            let ch = Int(m[0] & 0x0F)
            if playReported.allSatisfy({ $0 == nil }) { print("play : from djay's isPlaying (note \(playStateNote))") }
            playReported[ch] = (m[0] & 0xF0) == 0x90 && m[2] > 0
            return
        }

        // Play-button feedback: the fallback for a mapping without isPlaying.
        if m.count >= 3, Int(m[1]) == playNote,
           (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
            let ch = Int(m[0] & 0x0F)
            let lvl = (m[0] & 0xF0) == 0x90 && m[2] > 0
            if lvl != playLit[ch] { playLit[ch] = lvl; playLitSince[ch] = Date() }
        }

        // Note feedback is per deck. Remember it against the deck the host named and
        // light it only while that deck is the one in focus, so the other decks do
        // not fight over the single set of LEDs the deck actually has.
        if m.count >= 3, (0x80...0x9F).contains(m[0]) {
            let ch = Int(m[0] & 0x0F), n = Int(m[1])
            let vel: UInt8 = (m[0] & 0xF0) == 0x90 ? m[2] : 0
            if n == vinylNote {
                // djay's jog pitch-bend mode. Pinned off, and never shown: the lamp
                // belongs to motor mode now.
                bendMode[ch] = vel > 0
                if vel > 0 { pinScratchMode(ch) }
                return
            }
            ledShadow[ch][n] = vel
            ledSeen.insert(n)
            if ch == layer { paintNote(n, vel) }
            return
        }

        // The deck only has one platter, so re-address everything else to channel 1.
        toDevice(isChannelVoice(m.first ?? 0) ? [(m[0] & 0xF0)] + m.dropFirst() : m)
    }
    guard MIDIDestinationCreateWithBlock(client, virtName as CFString, &virtDst, { pktList, _ in
        let b = bytes(from: pktList)
        q.async { outSplitter.feed(b) }
    }) == noErr else {
        FileHandle.standardError.write("could not create virtual destination\n".data(using: .utf8)!); exit(1)
    }
    MIDIObjectSetIntegerProperty(virtDst, kMIDIPropertyUniqueID, 0x5C50_0002)
}

let idleTimer = DispatchSource.makeTimerSource(queue: q)
idleTimer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
var prefsPoll = 0
idleTimer.setEventHandler {
    if deckWentAway, findSource() == nil {
        print("deck disconnected — exiting so a fresh copy can wait for it")
        exit(0)
    }
    // Twice a second is quick enough to feel live from a slider and cheap enough to
    // ignore: one stat call. The idle timer is on q, so this never races a MIDI handler.
    prefsPoll += 1
    if prefsPoll % 10 == 0, prefsStamp() != lastPrefsStamp {
        lastPrefsStamp = prefsStamp()
        reloadPrefs()
    }
    // Play state, derived every tick rather than latched: waiting for the level to
    // hold still before adopting it never fires at all while the LED is blinking, so
    // the last value froze in place and the motor spun on through pause. A blink
    // simply fails "steady" and reads as paused.
    for ch in 0..<layerCount {
        let nowPlaying = playReported[ch]
            ?? (playLit[ch] && Date().timeIntervalSince(playLitSince[ch]) > motorDebounce)
        guard nowPlaying != deckPlays[ch] else { continue }
        deckPlays[ch] = nowPlaying
        print("  deck \(ch + 1) \(nowPlaying ? "playing" : "paused")")
        // A scratch held as its deck starts playing belongs to the other role now.
        if ch == layer, platterRole() != .scratch { setScratching(false) }
    }
    if motor, deckPlays[layer] != playing {
        playing = deckPlays[layer]
        if verbose { print("  play state -> \(playing ? "playing" : "paused")") }
        setMotor(motorMode && playing)
    }

    if platterGapMs > 0 { sendPlatter() }   // steps a stopped platter left behind

    if freeCoast, Date().timeIntervalSince(lastJogAt) > coastQuiet {
        freeCoast = false
        if verbose { print("  coast — platter at rest") }
    }

    guard scratching else { return }
    // Under a motor hold, stillness IS the hold — the motor would be turning the platter
    // otherwise — so neither the stillness release nor the cap applies. That hold ends
    // when the platter is back at the motor's speed.
    if motorRunning, vinylHold { return }
    if Date().timeIntervalSince(lastJogAt) > scratchIdle { setScratching(false); return }
    if Date().timeIntervalSince(scratchStartedAt) > scratchMax {
        if verbose { print("  scratch released — \(scratchMax)s cap") }
        setScratching(false)
    }
}
idleTimer.resume()

signal(SIGINT, SIG_IGN)
let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
sig.setEventHandler {
    print("\n\(passed) passed, \(dropped) dropped, \(returned) forwarded to device, \(flips) layer flips, \(jogSuppressed) motor-rotation reports gated")
    if layerEnabled && layerLED {
        toDevice([0x90, UInt8(layerNote), 0])
        toDevice([0x90, UInt8(platterRingNote), 0])
    }
    if padModeEnabled { for n in padModeNotes { toDevice([0x90, UInt8(n), 0]) } }
    toDevice([0x90, UInt8(vinylNote), 0])
    if motor && motorRunning { toDevice([0xB0, UInt8(motorStop), 0]) }
    MIDIEndpointDispose(virtSrc)
    if feedback { MIDIEndpointDispose(virtDst) }
    exit(0)
}
sig.resume()

setvbuf(stdout, nil, _IOLBF, 0)
print("in   : \(hwSrcName)")
print("out  : \(virtName)  (virtual source — select this in djay)")
if feedback, hwDst != nil {
    print("led  : \(virtName) → \(strProp(hwDst!, kMIDIPropertyDisplayName))")
} else {
    print("led  : disabled")
}
print("drop : \(drops.isEmpty && !dropPitch ? "nothing" : (drops.map { ($0.isNote ? "note " : "cc ") + String($0.d1) } + (dropPitch ? ["pitch bend"] : [])).joined(separator: ", "))")
if layerEnabled {
    print("layer: note \(layerNote) cycles \(layerCount) decks — deck N on channel N\(layerLED ? "  (ring tinted \(layerColours.prefix(layerCount).map(String.init).joined(separator: "/")))" : "")")
} else {
    print("layer: disabled — everything passes on its original channel")
}
print("led  : \(ledFull ? "buttons at full brightness" : "host level")\(padColour ? ", pads \(padModeColour.map(String.init).joined(separator: "/")) idle, \(padLitColour.map(String.init).joined(separator: "/")) lit, cues \(padCueColours.map(String.init).joined(separator: "/"))" : "")")
print("jog  : scratch on \(scratchEnter)+ ticks in \(Int(enterWindow * 1000))ms, release after \(Int(scratchIdle * 1000))ms idle, scale 1/\(scratchScale)")
print("prefs: \(prefsSummary())")
print("       \(prefsFound ? "from" : "defaults — no file yet at") \(prefsPath), re-read on change")
print("pads : \(padModeEnabled ? "HOT CUE/ROLL/SLICER/LOOP switch banks — notes \(padModeBase.map(String.init).joined(separator: "/")) + 0-7" : "always 32-39")")
let gateNote: String
if !jogGate { gateNote = "ungated" }
else if vinylHold { gateNote = "motor mode holds the track while a hand stops the platter, lets go at speed; bend stays on the buttons" }
else { gateNote = "motor rotation discarded while spinning; Vinyl (note \(vinylNote)) frees the platter" }
print("gate : \(gateNote)")
print("motor: \(motor ? "platter follows play state after \(motorDebounce)s debounce (CC \(motorStart) start / CC \(motorStop) stop)" : "disabled")")
print("\nrunning — Ctrl-C to stop\n")
if layerEnabled { showLayer() }
if padModeEnabled { showPadMode() }

CFRunLoopRun()
