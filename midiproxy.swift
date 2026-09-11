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
var motorStart = 65
var motorStop  = 66
var jogGate = true
var waitForDeck = false     // sit and wait for the deck rather than exiting
var vinylNote = 19          // STOP MOTOR button (spec calls it "Vinyl")
var shiftNote = 26          // SHIFT. Watched, never consumed: djay binds it as
                            // application.modifier and needs every press.
var shiftHeld = false
var vinylConsumed = false   // did WE take the current Vinyl press? Decides who gets
                            // the note-off, so releasing SHIFT first cannot strand it.
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

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    func next() -> String? { ai += 1; return ai < argv.count ? argv[ai] : nil }
    switch argv[ai] {
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
    case "--no-jog-gate":  jogGate = false
    case "--motor-touch":    motorTouch = true
    case "--no-motor-touch": motorTouch = false
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
          -p, --port <text>   hardware source to read      (default: SC5000)
          -n, --name <text>   virtual port name            (default: SC5000M Proxy)
          -d, --drop <list>   messages to filter out
                              default: note:56,cc:17,cc:49,pitch
                              note 56 is the heartbeat; CC 17/49 and pitch bend
                              duplicate the platter rotation that CC 54/55 already
                              carry, and pitch bend is an absolute angle that wraps
                              every revolution — feeding it to a relative jog
                              control makes the host jump wildly.
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
          has no touch sensor to tell them apart, so while the motor runs its
          rotation is discarded — otherwise the host seeks to the end of the track.

          The STOP MOTOR button switches between the two behaviours:
            motor mode   platter spins with playback, jog ignored
            manual mode  motor off, platter free, jog and scratching work

              --no-jog-gate     never discard rotation (host will seek on its own)
              --vinyl-note <n>  motor-mode button, held with SHIFT  (default 19)
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
              --motor-touch     EXPERIMENTAL: subtract the motor's learned rate
                                and forward the residual, so a driven platter can
                                still scratch. Off by default and best left off —
                                a hand moving at the motor's own speed reads as no
                                hand, and a throw wraps the 7-bit CC and plays
                                backwards. See the note on motorTouch in source.
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
var ledPlaying = false          // last play-LED level seen
var ledPlayingSince = Date()    // when it last changed
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
var ledFull = true          // buttons at full brightness rather than djay's level
// Pads 32-39 and the platter ring are RGB: velocity is a colour index, not brightness.
// djay sends its own level, so substitute the current bank's colour.
var padColour = true
let posCoarseCC = 17
var virtualPos = 0.0        // scaled position handed to the host
var lastSent = -1
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
    scratching = on
    if on { scratchStartedAt = Date() }
    emitToHost([0x90, UInt8(scratchNote), on ? 127 : 0])
    if verbose { print("  scratch \(on ? "start" : "end")") }
}
var motorStoppedAt = Date.distantPast
let coastWindow = 4.0       // platter keeps turning after a stop command

// Scratching on a driven platter. The deck has no touch sensor, but the motor has
// exactly one speed — so while it turns, rotation AT that speed is the motor and
// anything else is a hand. Learn the rate while nothing is touching, then subtract
// it: what is left is the hand's own movement, which is what the host should see.
// Steady motor leaves a residual of ~0 and nothing is forwarded, so the track does
// not run away; a hand leaves a large one and scratches.
var motorTouch = false      // EXPERIMENTAL, off by default: --motor-touch to try it.
                            // Subtracting the motor's rate does work in the steady
                            // case, but the edges defeat it. A hand sweeping through
                            // the motor's own speed is indistinguishable from no hand;
                            // a throw makes per-message residuals big enough that the
                            // host misreads the 7-bit wrap and plays the throw
                            // backwards; and the coast window keeps this path live for
                            // seconds after the motor stops, where a stale rate turns
                            // a freed platter into a runaway. The deck gives no touch
                            // signal, so all of it is inference, and the failure modes
                            // sit exactly where the inference is weakest. Motor and
                            // scratching stay separate modes on SHIFT+Vinyl instead.
var baseRate = 0.0          // ticks/sec the motor alone produces, learned live
var baseSeeded = false
var lastPosAt = Date.distantPast
var devRun = 0              // consecutive samples away from the learned rate
var rateSamples: [Double] = []      // gathered to seed baseRate from a settled platter
var motorSettleUntil = Date.distantPast
// djay reports its own jog mode by lighting note 19: LIT means pitch bend, dark means
// scratch. Read it back so the platter only ever drives the control that is actually
// live — both were bound at once (scratchingMove on CC 49, pitchBendMove on CC 54) and
// a host that acts on both scratches and nudges tempo off one hand movement.
var bendMode = [Bool](repeating: false, count: 16)
var belowSince = Date.distantPast    // when the rate first settled back to the motor's
var posHist: [(Date, Int)] = []     // recent unwrapped positions, for a smoothed rate
var unwrapped = 0                   // running tick count, free of the 14-bit wrap
// Rate has to be measured over a window, never per message. Each report carries 1-4
// whole ticks over ~1-4ms, so a per-message d/dt swings by ±1000 ticks/s on the
// integer alone -- far past any sane threshold, which makes it chatter with nothing
// touching the platter. Over 60ms the same quantum is a rounding error.
let rateWindow = 0.06
// Thresholds as a fraction of the motor's own rate rather than absolute: the deck
// turns out to run ~2000 ticks/s, not the ~750 the spec estimated from message
// counts, so fixed figures sized against that guess were wildly too tight.
let touchEnterFrac = 0.35   // this far off the motor's rate means a hand is on
let touchExitFrac  = 0.18   // ... and the lower bar to stay on, so it cannot chatter
let touchEnterRun = 3
// Leaving has to be judged on time, not samples. A hand sweeps through the motor's
// own speed on every stroke, and for that instant a held platter is indistinguishable
// from a free one -- 3 samples is ~7ms at this report rate, so every stroke dropped
// the scratch and picked it straight back up. A released platter STAYS at the motor's
// rate, so requiring the match to persist tells the two apart.
let touchExitHold = 0.20

/// Rotation reports: the documented jog pair, the two undocumented twins, and pitch bend.
func isJogReport(_ m: [UInt8]) -> Bool {
    guard let st = m.first else { return false }
    if (st & 0xF0) == 0xE0 { return true }
    if (st & 0xF0) == 0xB0, m.count >= 2 { return jogCCs.contains(Int(m[1])) }
    return false
}

func setMotor(_ on: Bool) {
    guard motor, on != motorRunning else { return }
    motorRunning = on
    if !on { motorStoppedAt = Date() }
    // The rate is about to change, so the learned one is worthless. Spin-up and
    // spin-down both sweep through every rate between zero and cruising: seeding
    // anywhere in there gives a baseline the platter never returns to, and the
    // deviation then never falls back under the exit bar — the hand looks like it
    // is on the platter for ever, which is exactly how the motor's own rotation
    // leaks out as endless drift.
    baseSeeded = false
    rateSamples.removeAll()
    posHist.removeAll()
    devRun = 0
    motorSettleUntil = Date().addingTimeInterval(1.5)
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

/// Lights LAYER off deck 1, and tints the platter ring to the current deck's colour.
func showLayer() {
    guard layerLED else { return }
    toDevice([0x90, UInt8(layerNote), layer == 0 ? 0 : 127])
    if !layerColours.isEmpty {
        let c = layerColours[layer % layerColours.count]
        toDevice([0x90, UInt8(platterRingNote), UInt8(c & 0x7F)])
    }
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

    // SHIFT+Vinyl toggles between a spinning platter and a free one. PLAIN Vinyl is
    // djay's, where it switches the platter between scratching and pitch-bend
    // nudging — so one button can carry both without its meaning depending on
    // whether the proxy happens to be driving the motor. Only the press we actually
    // took is swallowed, note-off included, so letting go of SHIFT first cannot
    // leave djay holding half a press.
    if motor, m.count >= 3, Int(m[1]) == vinylNote {
        let isPress = (m[0] & 0xF0) == 0x90 && m[2] > 0
        if isPress, shiftHeld {
            vinylConsumed = true
            motorMode.toggle()
            setMotor(motorMode && playing)
            print(motorMode ? "  motor mode — platter spins with playback, jog ignored"
                            : "  manual mode — motor off, platter free to scratch")
            return
        }
        if isPress { vinylConsumed = false }
        if !isPress, vinylConsumed { vinylConsumed = false; return }
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
        // pitch bend stays on the PITCH BEND -/+ buttons while the motor runs.
        if !(motorTouch && isPos) {
            jogSuppressed += 1
            return
        }
    }

    // LAYER is consumed here: it toggles deck focus and never reaches the host.
    if layerEnabled, m.count >= 3, Int(m[1]) == layerNote,
       (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
        let isPress = (m[0] & 0xF0) == 0x90 && m[2] > 0
        if isPress {
            // release anything still held, on the layer it was pressed on
            for n in heldNotes {
                withPacketList(onLayer([0x90, n, 0])) { pl in MIDIReceived(virtSrc, pl) }
            }
            heldNotes.removeAll()
            padHeldMode = [Int](repeating: -1, count: 8)   // those releases are now sent
            layer = (layer + 1) % layerCount
            flips += 1
            showLayer()
            showDeckLEDs()          // the new deck's LEDs, as the host last described them
            print("  layer \(Character(UnicodeScalar(65 + layer)!)) — deck \(layer + 1) (channel \(layer + 1))")
        }
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
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, Int(m[1]) == posCC, !bendMode[layer] {
        let now = Date()
        lastJogAt = now
        // CC 49 wraps several times per revolution; unwrap it, scale it down, and
        // hand the host a position that moves at a sane rate.
        let raw = (coarse << 7) | Int(m[2])

        if driven, motorTouch {
            // Driven platter: tell hand from motor by rate, not by presence.
            var d = 0, dt = 0.0
            if lastPos >= 0 {
                d = raw - lastPos
                if d >  8192 { d -= 16384 }
                if d < -8192 { d += 16384 }
                dt = now.timeIntervalSince(lastPosAt)
            }
            lastPos = raw
            lastPosAt = now
            guard dt > 0.0005, dt < 0.25 else { return }   // no basis for a rate yet

            unwrapped += d
            posHist.append((now, unwrapped))
            posHist.removeAll { now.timeIntervalSince($0.0) > rateWindow }
            if now < motorSettleUntil { return }       // still spinning up or down
            guard let oldest = posHist.first else { return }
            let span = now.timeIntervalSince(oldest.0)
            guard span >= rateWindow * 0.5 else { return }  // not enough history yet
            let rate = Double(unwrapped - oldest.1) / span

            if !baseSeeded {
                // Seed from the middle of a batch, and only if the batch is tight.
                // A hand resting on the platter during seeding spreads the samples,
                // and a spread batch is thrown away rather than trusted.
                rateSamples.append(rate)
                guard rateSamples.count >= 24 else { return }
                let sorted = rateSamples.sorted()
                let med = sorted[sorted.count / 2]
                let spread = sorted[(sorted.count * 3) / 4] - sorted[sorted.count / 4]
                if abs(med) > 1, spread < abs(med) * 0.15 { baseRate = med; baseSeeded = true }
                rateSamples.removeAll()
                if verbose, baseSeeded { print("  motor rate learned: \(Int(baseRate)) ticks/s") }
                return                                     // never scratch before it is known
            }

            if !scratching {
                let dev = abs(rate - baseRate)
                // Only ever learn from rotation that looks like the motor, or the
                // baseline chases the hand and the deviation vanishes.
                if dev < abs(baseRate) * touchExitFrac { baseRate = baseRate * 0.95 + rate * 0.05 }
                devRun = dev > abs(baseRate) * touchEnterFrac ? devRun + 1 : 0
                guard devRun >= touchEnterRun else { return }  // motor alone: host sees nothing
                devRun = 0
                belowSince = Date.distantPast
                setScratching(true)
                return                                    // start clean on the next sample
            }
            // Released: the platter settles back to the motor's rate AND stays there.
            if abs(rate - baseRate) < abs(baseRate) * touchExitFrac {
                if belowSince == Date.distantPast { belowSince = now }
                if now.timeIntervalSince(belowSince) > touchExitHold {
                    belowSince = Date.distantPast
                    setScratching(false)
                    return
                }
            } else {
                belowSince = Date.distantPast
            }
            // Deadband. Staying in scratch mode through the settle is right -- it stops
            // the chatter -- but FEEDING movement through it is not: a platter coming
            // back down from a throw dips under the motor's rate before the servo
            // catches it, and that shows up as the track playing backwards for a
            // moment. Inside the release band the platter is doing the motor's work,
            // not the hand's, so hand movement is zero by definition.
            guard abs(rate - baseRate) > abs(baseRate) * touchExitFrac else { return }
            virtualPos += (Double(d) - baseRate * dt) / scratchScale
        } else {
            if !scratching {
                recentTicks.append(now)
                recentTicks.removeAll { now.timeIntervalSince($0) > enterWindow }
                guard recentTicks.count >= scratchEnter else {
                    jogSuppressed += 1
                    return                   // stray tick: never reaches the host
                }
                recentTicks.removeAll()
                lastPos = -1
                setScratching(true)
            }
            if lastPos >= 0 {
                var d = raw - lastPos
                if d >  8192 { d -= 16384 }
                if d < -8192 { d += 16384 }
                virtualPos += Double(d) / scratchScale
            }
            lastPos = raw
            lastPosAt = now
        }
        let outVal = ((Int(virtualPos.rounded()) % 128) + 128) % 128
        guard outVal != lastSent else { return }
        lastSent = outVal
        passed += 1
        if verbose { print("  pass  ch\(layer + 1) CC \(posCC) = \(outVal)  (scaled 1/\(scratchScale))") }
        emitToHost([m[0], m[1], UInt8(outVal)])
        return
    }

    // Scale the platter down: accumulate ticks, emit one step per `jogDivisor`.
    // Only while djay says the deck is in pitch-bend mode — otherwise the platter
    // drives scratchingMove and pitchBendMove off the same movement at once.
    if m.count >= 3, (m[0] & 0xF0) == 0xB0, Int(m[1]) == 54, bendMode[layer] {
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

        // Play-button feedback for the layer we are on drives the platter motor.
        if motor, m.count >= 3, Int(m[1]) == playNote,
           (m[0] & 0xF0) == 0x90 || (m[0] & 0xF0) == 0x80 {
            let ch = Int(m[0] & 0x0F)
            if ch == layer {
                let lvl = (m[0] & 0xF0) == 0x90 && m[2] > 0
                if lvl != ledPlaying { ledPlaying = lvl; ledPlayingSince = Date() }
            }
        }

        // Note feedback is per deck. Remember it against the deck the host named and
        // light it only while that deck is the one in focus, so the other decks do
        // not fight over the single set of LEDs the deck actually has.
        if m.count >= 3, (0x80...0x9F).contains(m[0]) {
            let ch = Int(m[0] & 0x0F), n = Int(m[1])
            var vel: UInt8 = (m[0] & 0xF0) == 0x90 ? m[2] : 0
            if n == vinylNote {
                bendMode[ch] = vel > 0
                // Invert the lamp: djay lights it for pitch bend, but the panel reads
                // better with the light meaning "the platter scratches".
                vel = vel > 0 ? 0 : 127
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
idleTimer.setEventHandler {
    if deckWentAway, findSource() == nil {
        print("deck disconnected — exiting so a fresh copy can wait for it")
        exit(0)
    }
    // Play state. djay does not signal it by level: it holds the play LED solid to
    // mean playing and BLINKS it at 0.5s on/off to mean paused, so "lit" alone is
    // true half the time in both states. Steady-and-lit is the only reading that
    // means playing, and it has to be derived every tick rather than latched --
    // waiting for the level to hold still before adopting it never fires at all
    // while the LED is blinking, so the last value froze in place and the motor
    // spun on through pause. A blink now simply fails "steady" and reads as paused.
    if motor {
        let steady = Date().timeIntervalSince(ledPlayingSince) > motorDebounce
        let nowPlaying = ledPlaying && steady
        if nowPlaying != playing {
            playing = nowPlaying
            if verbose { print("  play state -> \(playing ? "playing" : "paused")") }
            setMotor(motorMode && playing)
        }
    }

    guard scratching else { return }
    // On a driven platter the motor keeps rotation reports coming, so the stillness
    // test below never fires. A scratch that outlasts this is not a long scratch, it
    // is a baseline that no longer matches the platter — drop it and learn again
    // rather than leaking motor rotation to the host indefinitely.
    if motor, motorTouch, motorRunning,
       Date().timeIntervalSince(scratchStartedAt) > 12.0 {
        if verbose { print("  scratch released — re-learning the motor rate") }
        setScratching(false)
        baseSeeded = false
        rateSamples.removeAll()
        devRun = 0
        return
    }
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
print("pads : \(padModeEnabled ? "HOT CUE/ROLL/SLICER/LOOP switch banks — notes \(padModeBase.map(String.init).joined(separator: "/")) + 0-7" : "always 32-39")")
let gateNote: String
if !jogGate { gateNote = "ungated" }
else if motorTouch { gateNote = "hand told from motor by rate — scratch works while it spins; bend stays on the buttons" }
else { gateNote = "motor rotation discarded while spinning; SHIFT+Vinyl (note \(shiftNote)+\(vinylNote)) frees the platter" }
print("gate : \(gateNote)")
print("motor: \(motor ? "platter follows play state after \(motorDebounce)s debounce (CC \(motorStart) start / CC \(motorStop) stop)" : "disabled")")
print("\nrunning — Ctrl-C to stop\n")
if layerEnabled { showLayer() }
if padModeEnabled { showPadMode() }

CFRunLoopRun()
