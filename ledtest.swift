import CoreMIDI
import Foundation

// Does the SC5000M light up from generic MIDI, or is LED control gated behind
// Denon's proprietary handshake?  Send notes at it and watch the deck.

var portFilter = "SC5000M Prime Controller"
var mode = "sweep"
var note = 1
var vel = 127
var dwell = 0.7
var page = 0
var loNote = 0
var ccNum = -1
var ccVal = 127
var hiNote = 127
var colours: [Int] = []
var holds: [(Int, Int)] = []

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    func next() -> String? { ai += 1; return ai < argv.count ? argv[ai] : nil }
    switch argv[ai] {
    case "-p", "--port":  portFilter = next() ?? portFilter
    case "-n", "--note":  note = Int(next() ?? "") ?? note; mode = "one"
    case "-v", "--vel":   vel = Int(next() ?? "") ?? vel
    case "-t", "--dwell": dwell = Double(next() ?? "") ?? dwell
    case "--sweep":       mode = "sweep"
    case "--pads":        mode = "pads"
    case "--palette":     mode = "palette"
    case "--colours":     colours = (next() ?? "").split(separator: ",").compactMap { Int($0) }
                          mode = "colours"
    case "--hold":        holds = (next() ?? "").split(separator: ",").compactMap { pair in
                              let kv = pair.split(separator: ":")
                              guard kv.count == 2, let n = Int(kv[0]), let c = Int(kv[1]) else { return nil }
                              return (n, c)
                          }
                          mode = "hold"
    case "--every":       mode = "every"
    case "--ccscan":      mode = "ccscan"
    case "--cc":          ccNum = Int(next() ?? "") ?? ccNum; mode = "cc"
    case "--val":         ccVal = Int(next() ?? "") ?? ccVal
    case "--scan":        mode = "scan"
    case "--from":        loNote = Int(next() ?? "") ?? loNote
    case "--to":          hiNote = Int(next() ?? "") ?? hiNote
    case "--page":        page = Int(next() ?? "") ?? page; mode = "palette"
    case "--all":         mode = "all"
    case "--off":         mode = "off"
    case "-h", "--help":
        print("""
        ledtest — drive the deck's LEDs over plain MIDI

        usage: ledtest [options]
          --sweep           light each known LED in turn, naming it  (default)
          --pads            cycle the 8 pads through colour indices
          --every           light ALL 128 note numbers at once and hold
          --ccscan          step every CC 0-127 (value 127 then 0), printing each
          --cc <n>          send one CC and hold it
          --val <n>         value for --cc  (default 127)
          --scan            step every note number one at a time, printing it
          --from <n>        scan lower bound  (default 0)
          --to <n>          scan upper bound  (default 127)
          --palette         show 8 colour indices at once, one per pad, and hold
          --colours <list>  hold one named colour index per pad, left to right —
                            for checking a set you mean to put in midiproxy
          --hold <list>     hold any notes at any colour indices, note:index —
                            lighting several at once says whether an LED is RGB
                            at all, since a single-colour one ignores the index
          --page <n>        which block of 8 to show (0 = indices 1-8, 1 = 9-16, ...)
          --all             light everything at once
          --off             blackout: note-off every known LED
          -n, --note <n>    light one note and hold it
          -v, --vel <n>     velocity / colour index  (default 127)
          -t, --dwell <s>   seconds per step         (default 0.7)
          -p, --port <text> destination to send to   (default: the raw deck)

        Watch the deck while this runs and note which controls light.
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(argv[ai])\n".data(using: .utf8)!); exit(2)
    }
    ai += 1
}

func strProp(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

let simple: [(Int, String)] = [
    (1, "Play/Pause"), (2, "Cue"), (3, "Beat Jump Back"), (4, "Beat Jump Fwd"),
    (5, "Track Skip Prev"), (6, "Track Skip Next"), (7, "Censor"),
    (8, "Loop In"), (9, "Loop Out"), (10, "Auto Loop"),
    (11, "LAYER"), (12, "SHORTCUT"), (13, "SOURCE"), (14, "VIEW"),
    (18, "Light Ring Select"), (19, "Light Ring Vinyl"), (20, "Sync"),
    (21, "Master Deck"), (22, "Key Lock"), (23, "Slip"),
    (24, "Pitch -"), (25, "Pitch +"), (26, "Shift"),
    (27, "Hot Cue Mode"), (28, "Roll Mode"), (29, "Slicer Mode"), (30, "Loop Mode"),
    (41, "Pitch Arrow Back"), (42, "Pitch Center"), (43, "Pitch Arrow Fwd"),
    (68, "Parameter Back"), (69, "Parameter Fwd"),
]
let rgb: [(Int, String)] = (32...39).map { ($0, "Pad \($0 - 31)") } + [(40, "Platter LED Ring")]

func primeCCName(_ c: Int) -> String? {
    switch c {
    case 3:  return "Auto Loop Size"
    case 6:  return "Select turn"
    case 8:  return "Pitch Slider MSB"
    case 40: return "Pitch Slider LSB"
    case 54: return "Jog Wheel LSB"
    case 55: return "Jog Wheel MSB"
    case 64: return "Needle Drop scrub"
    default: return nil
    }
}

let dests = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
    .filter { strProp($0, kMIDIPropertyDisplayName).localizedCaseInsensitiveContains(portFilter) }
guard let dst = dests.first else {
    FileHandle.standardError.write("no MIDI destination matching \"\(portFilter)\"\n".data(using: .utf8)!)
    exit(1)
}

var client = MIDIClientRef(); var port = MIDIPortRef()
MIDIClientCreateWithBlock("ledtest" as CFString, &client, nil)
MIDIOutputPortCreate(client, "ledtest-out" as CFString, &port)

func send(_ m: [UInt8]) {
    let size = 512
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { raw.deallocate() }
    let pl = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
    let cur = MIDIPacketListInit(pl)
    _ = MIDIPacketListAdd(pl, size, cur, 0, m.count, m)
    MIDISend(port, dst, UnsafePointer(pl))
}

func on(_ n: Int, _ v: Int = 127)  { send([0x90, UInt8(n), UInt8(v)]) }
func off(_ n: Int)                 { send([0x90, UInt8(n), 0]) }
func allOff()                      { for (n, _) in simple + rgb { off(n) } }

print("target: \(strProp(dst, kMIDIPropertyDisplayName))")
print("mode  : \(mode)\n")

switch mode {
case "one":
    print("note \(note) velocity \(vel) — holding. Ctrl-C to stop.")
    on(note, vel)
    CFRunLoopRun()

case "all":
    print("lighting every known LED at velocity \(vel)")
    for (n, name) in simple { on(n, vel); print("  note \(n)  \(name)") }
    for (n, name) in rgb   { on(n, vel); print("  note \(n)  \(name)  (colour index \(vel))") }
    print("\nholding. Ctrl-C to stop.")
    CFRunLoopRun()

case "off":
    allOff(); print("blackout sent to \(simple.count + rgb.count) LEDs")

case "cc":
    print("CC \(ccNum) = \(ccVal) — holding. Ctrl-C to stop.")
    send([0xB0, UInt8(ccNum), UInt8(ccVal)])
    CFRunLoopRun()

case "ccscan":
    print("stepping CC 0-127 at \(dwell)s each, value 127 then 0")
    print("watch the platter and the screen — call out any CC that does something\n")
    for c in 0...127 {
        let known = primeCCName(c)
        print("  cc \(String(format: "%3d", c))\(known.map { "  [\($0)]" } ?? "")")
        send([0xB0, UInt8(c), UInt8(ccVal)])
        Thread.sleep(forTimeInterval: dwell)
        send([0xB0, UInt8(c), 0])
    }
    print("\nCC scan complete")

case "every":
    print("lighting all 128 note numbers at velocity \(vel)")
    print("anything undocumented that can light, will light now\n")
    for n in 0...127 { on(n, vel) }
    print("holding. Ctrl-C to stop.")
    CFRunLoopRun()

case "scan":
    print("stepping notes \(loNote)-\(hiNote) at \(dwell)s each")
    print("call out the note number when a button you care about lights\n")
    for n in loNote...hiNote {
        let known = (simple + rgb).first { $0.0 == n }?.1
        print("  note \(String(format: "%3d", n))\(known.map { "  [\($0)]" } ?? "")")
        on(n, vel); Thread.sleep(forTimeInterval: dwell); off(n)
    }
    allOff(); print("\nscan complete")

case "palette":
    let base = page * 8 + 1
    print("holding pads at colour indices \(base)-\(base + 7) — read the colours off left to right\n")
    for (i, (n, name)) in rgb.prefix(8).enumerated() {
        let idx = base + i
        on(n, idx)
        print("  \(name)  ->  colour index \(idx)")
    }
    print("\nholding. Ctrl-C to stop.")
    CFRunLoopRun()

case "hold":
    print("holding the notes you named\n")
    for (n, c) in holds {
        on(n, c)
        print("  note \(n)  ->  colour index \(c)")
    }
    print("\nholding. Ctrl-C to stop.")
    CFRunLoopRun()

case "colours":
    print("holding the pads at the indices you named — read them off left to right\n")
    for (i, (n, name)) in rgb.prefix(8).enumerated() where i < colours.count {
        on(n, colours[i])
        print("  \(name)  ->  colour index \(colours[i])")
    }
    print("\nholding. Ctrl-C to stop.")
    CFRunLoopRun()

case "pads":
    print("cycling pads through colour indices — watch for colour changes\n")
    for colour in [1, 4, 9, 16, 25, 33, 41, 49, 57, 64] {
        print("  colour index \(colour)")
        for (n, _) in rgb { on(n, colour) }
        Thread.sleep(forTimeInterval: dwell)
    }
    allOff(); print("\ndone")

default:  // sweep
    print("one LED at a time — call out which ones actually light\n")
    for (n, name) in simple {
        print("  note \(String(format: "%2d", n))  \(name)")
        on(n, vel); Thread.sleep(forTimeInterval: dwell); off(n)
    }
    for (n, name) in rgb {
        print("  note \(String(format: "%2d", n))  \(name)  (RGB)")
        on(n, vel); Thread.sleep(forTimeInterval: dwell); off(n)
    }
    allOff(); print("\ndone — anything light up?")
}
