import CoreMIDI
import Foundation

// ───────────────────────────── options ─────────────────────────────

let defaultMap = "\(NSHomeDirectory())/Music/djay/MIDI Mappings/SC5000M_Prime_Controller_Jack_1_dualdeck_SHIFT_parked.djayMidiMapping"

var portFilter = "SC5000"
var mapPath: String? = defaultMap
var raw = false
var listOnly = false
var logPath: String? = nil
var muteSpec = ""

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    func next() -> String? { ai += 1; return ai < argv.count ? argv[ai] : nil }
    switch argv[ai] {
    case "-l", "--list":  listOnly = true
    case "--raw":         raw = true
    case "--no-map":      mapPath = nil
    case "-p", "--port":  portFilter = next() ?? portFilter
    case "-m", "--map":   mapPath = next()
    case "--log":         logPath = next()
    case "--mute":        muteSpec = next() ?? ""
    case "-h", "--help":
        print("""
        midimon — live MIDI monitor for the Denon SC5000M Prime

        usage: midimon [options]
          -l, --list          list MIDI sources and exit
          -p, --port <text>   substring of source name to open   (default: SC5000)
          -m, --map <path>    .djayMidiMapping used to label known controls
              --no-map        do not label
              --raw           print every message; do not coalesce continuous streams
              --log <path>    append every event to a TSV file
              --mute <list>   hide controls, e.g. --mute note:56,cc:55,cc:54

        Ctrl-C prints a summary of every distinct control seen.
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown option: \(argv[ai])\n".data(using: .utf8)!)
        exit(2)
    }
    ai += 1
}

// ───────────────────────────── CoreMIDI helpers ─────────────────────────────

func strProp(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

func sources() -> [(MIDIEndpointRef, String)] {
    (0..<MIDIGetNumberOfSources()).map { i in
        let e = MIDIGetSource(i)
        return (e, strProp(e, kMIDIPropertyDisplayName))
    }
}

if listOnly {
    print("sources (device → computer):")
    for (i, s) in sources().enumerated() { print("  [\(i)] \(s.1)") }
    print("destinations (computer → device):")
    for i in 0..<MIDIGetNumberOfDestinations() {
        print("  [\(i)] \(strProp(MIDIGetDestination(i), kMIDIPropertyDisplayName))")
    }
    exit(0)
}

// ───────────────────────────── djay mapping ─────────────────────────────

// djay midiMessageType: 1 = note, 3 = control change, 6 = pitch bend
struct MapKey: Hashable { let type: Int; let ch: Int; let data: Int }

var labels: [MapKey: [String]] = [:]

if let mp = mapPath {
    if let data = FileManager.default.contents(atPath: mp),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let controls = plist["controls"] as? [[String: Any]] {
        for c in controls {
            guard let t = c["midiMessageType"] as? Int,
                  let ch = c["midiChannel"] as? Int,
                  let d = c["midiData"] as? Int,
                  var kp = c["keyPath"] as? String else { continue }
            if (c["modifier"] as? Bool) == true { kp = "SHIFT+" + kp }
            labels[MapKey(type: t, ch: ch, data: d), default: []].append(kp)
        }
        print("mapping: \((mp as NSString).lastPathComponent) — \(controls.count) controls, \(labels.count) distinct addresses")
    } else {
        print("mapping: could not read \(mp) — continuing unlabelled")
    }
}

func label(type: Int, ch: Int, data: Int) -> String {
    guard let l = labels[MapKey(type: type, ch: ch, data: data)] else { return "" }
    return l.joined(separator: " / ")
}

// ───────────────────── Denon Prime factory names (LC6000 spec v1.0) ─────────────────────

let primeNotes: [Int: String] = [
    1: "Play/Pause", 2: "Cue", 3: "Beat Jump Back", 4: "Beat Jump Fwd",
    5: "Track Skip Prev", 6: "Track Skip Next", 7: "Censor", 8: "Loop In",
    9: "Loop Out", 10: "Auto Loop Set",
    11: "LAYER", 12: "SHORTCUT", 13: "SOURCE", 14: "VIEW",
    16: "Back", 17: "Forward",
    18: "Select (press)", 19: "Vinyl", 20: "Sync", 21: "Master Deck",
    22: "Key Lock", 23: "Slip", 24: "Pitch -", 25: "Pitch +", 26: "SHIFT",
    27: "Hot Cue Mode", 28: "Roll Mode", 29: "Slicer Mode", 30: "Loop Mode",
    32: "Pad 1", 33: "Pad 2", 34: "Pad 3", 35: "Pad 4",
    36: "Pad 5", 37: "Pad 6", 38: "Pad 7", 39: "Pad 8",
    40: "Platter Touch", 41: "LED Pitch Arrow Back", 42: "LED Pitch Center",
    43: "LED Pitch Arrow Fwd", 68: "Parameter Back", 69: "Parameter Fwd",
    70: "Needle Drop (touch)",
]

let primeCCs: [Int: String] = [
    3: "Auto Loop Size (turn)", 6: "Select (turn)",
    8: "Pitch Slider MSB", 40: "Pitch Slider LSB",
    54: "Jog Wheel LSB", 55: "Jog Wheel MSB",
    64: "Needle Drop (scrub)",
]

func primeName(_ kind: Kind, _ d1: Int) -> String {
    switch kind {
    case .noteOn, .noteOff, .poly: return primeNotes[d1] ?? ""
    case .cc:                      return primeCCs[d1] ?? ""
    case .pitch:                   return "pitch bend"
    default:                       return ""
    }
}

/// Relative-encoder decode: forward 1..63, reverse 127..64 (two's complement in 7 bits).
func relDelta(_ v: Int) -> Int { v >= 64 ? v - 128 : v }

func isRelative(_ kind: Kind, _ d1: Int) -> Bool {
    kind == .cc && [3, 6, 54, 55].contains(d1)
}

// ───────────────────────────── events ─────────────────────────────

enum Kind: String { case noteOn, noteOff, poly, cc, program, pressure, pitch, sysex, common, realtime }

struct Event {
    var kind: Kind
    var ch: Int          // 0-based; -1 for system messages
    var d1: Int
    var d2: Int
    var value: Int       // velocity / cc value / 14-bit bend
    var bytes: [UInt8] = []
    var time: Double
}

/// (kind, channel, data) identity — what a mapping entry addresses.
struct EventKey: Hashable { let kind: Kind; let ch: Int; let d1: Int }
struct EventKeyLite: Hashable { let isNote: Bool; let d1: Int }

let continuous: Set<Kind> = [.cc, .pitch, .pressure, .poly]

func djayType(_ k: Kind) -> Int? {
    switch k {
    case .noteOn, .noteOff: return 1
    case .cc:               return 3
    case .pitch:            return 6
    default:                return nil
    }
}

let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
func noteName(_ n: Int) -> String { "\(noteNames[n % 12])\(n / 12 - 1)" }

// ───────────────────────────── byte-stream parser ─────────────────────────────

final class Parser {
    private var status: UInt8 = 0
    private var buf: [UInt8] = []
    private var inSysex = false
    private var sysex: [UInt8] = []
    var onEvent: (Event) -> Void = { _ in }

    private func expected(_ s: UInt8) -> Int {
        switch s & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch s { case 0xF1, 0xF3: return 1; case 0xF2: return 2; default: return 0 }
        default: return 2
        }
    }

    func feed(_ bytes: [UInt8], at t: Double) {
        for b in bytes {
            if b >= 0xF8 {                                   // realtime — never disturbs running status
                onEvent(Event(kind: .realtime, ch: -1, d1: Int(b), d2: 0, value: 0, time: t))
                continue
            }
            if inSysex {
                if b == 0xF7 {
                    inSysex = false
                    onEvent(Event(kind: .sysex, ch: -1, d1: 0, d2: 0, value: 0, bytes: sysex, time: t))
                    sysex = []
                } else if b >= 0x80 {
                    inSysex = false; sysex = []; handleStatus(b, t)
                } else {
                    sysex.append(b)
                }
                continue
            }
            if b >= 0x80 { handleStatus(b, t) } else { buf.append(b); tryEmit(t) }
        }
    }

    private func handleStatus(_ b: UInt8, _ t: Double) {
        buf = []
        if b == 0xF0 { inSysex = true; sysex = []; status = 0; return }
        status = b
        if expected(b) == 0 {
            onEvent(Event(kind: .common, ch: -1, d1: Int(b), d2: 0, value: 0, time: t))
            status = 0
        }
    }

    private func tryEmit(_ t: Double) {
        guard status != 0, buf.count == expected(status) else { return }
        let ch = Int(status & 0x0F)
        let d1 = Int(buf[0])
        let d2 = buf.count > 1 ? Int(buf[1]) : 0
        buf = []                                             // keep status for running-status runs

        switch status & 0xF0 {
        case 0x80: onEvent(Event(kind: .noteOff,  ch: ch, d1: d1, d2: d2, value: d2, time: t))
        case 0x90: onEvent(Event(kind: d2 == 0 ? .noteOff : .noteOn, ch: ch, d1: d1, d2: d2, value: d2, time: t))
        case 0xA0: onEvent(Event(kind: .poly,     ch: ch, d1: d1, d2: d2, value: d2, time: t))
        case 0xB0: onEvent(Event(kind: .cc,       ch: ch, d1: d1, d2: d2, value: d2, time: t))
        case 0xC0: onEvent(Event(kind: .program,  ch: ch, d1: d1, d2: 0,  value: d1, time: t))
        case 0xD0: onEvent(Event(kind: .pressure, ch: ch, d1: 0,  d2: 0,  value: d1, time: t))
        case 0xE0: onEvent(Event(kind: .pitch,    ch: ch, d1: 0,  d2: 0,  value: (d2 << 7) | d1, time: t))
        default:   break
        }
    }
}

// ───────────────────────────── printing ─────────────────────────────

let q = DispatchQueue(label: "midimon")
let start = Date().timeIntervalSince1970

struct Stat { var count = 0; var minV = Int.max; var maxV = Int.min; var last = 0.0 }
var stats: [EventKey: Stat] = [:]

var logFH: FileHandle? = {
    guard let lp = logPath else { return nil }
    if !FileManager.default.fileExists(atPath: lp) { FileManager.default.createFile(atPath: lp, contents: nil) }
    let fh = FileHandle(forWritingAtPath: lp)
    fh?.seekToEndOfFile()
    fh?.write("# t\tkind\tch\td1\td2\tvalue\tlabel\n".data(using: .utf8)!)
    return fh
}()

func desc(_ e: Event) -> (String, String, String) {   // (kind, address, value)
    switch e.kind {
    case .noteOn, .noteOff:
        return (e.kind == .noteOn ? "Note On" : "Note Off", "note \(e.d1)", "vel \(e.value)")
    case .cc:
        if isRelative(e.kind, e.d1) {
            let d = relDelta(e.value)
            return ("CC", "cc \(e.d1)", "\(e.value)  (\(d > 0 ? "+" : "")\(d))")
        }
        return ("CC", "cc \(e.d1)", "\(e.value)")
    case .pitch:    return ("Pitch Bend",   "—",                 "\(e.value)  (\(e.value - 8192 >= 0 ? "+" : "")\(e.value - 8192))")
    case .poly:     return ("Poly AT",      "note \(e.d1)",      "\(e.value)")
    case .pressure: return ("Chan AT",      "—",                 "\(e.value)")
    case .program:  return ("Program",      "—",                 "\(e.value)")
    case .sysex:
        let hex = e.bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        return ("SysEx", "\(e.bytes.count) bytes", hex + (e.bytes.count > 24 ? " …" : ""))
    case .common:   return ("System",       String(format: "0x%02X", e.d1), "")
    case .realtime: return ("Realtime",     String(format: "0x%02X", e.d1), "")
    }
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func emitLine(_ e: Event, repeats: Int, from: Int?) {
    let (kind, addr, val) = desc(e)
    var lbl = ""
    if let t = djayType(e.kind) { lbl = label(type: t, ch: e.ch, data: e.d1) }
    let chs = e.ch >= 0 ? "ch\(e.ch + 1)" : "—"
    var value = val
    if let f = from, f != e.value { value = "\(f) → \(e.value)" }
    let rep = repeats > 1 ? "  ×\(repeats)" : ""
    let time = String(format: "%8.3f", e.time - start)
    let pname = primeName(e.kind, e.d1)
    print("\(time)  \(pad(chs, 5))\(pad(kind, 11))\(pad(addr, 10))\(pad(value, 18))\(pad(pname, 24))\(lbl.isEmpty ? "" : "→ " + lbl)\(rep)")
}

// coalesce consecutive continuous messages from the same control
var pending: (event: Event, count: Int, first: Int)? = nil

func flushPending() {
    if let p = pending { emitLine(p.event, repeats: p.count, from: p.first); pending = nil }
}

func record(_ e: Event) {
    let k = EventKey(kind: e.kind, ch: e.ch, d1: e.d1)
    var s = stats[k] ?? Stat()
    s.count += 1
    s.minV = min(s.minV, e.value)
    s.maxV = max(s.maxV, e.value)
    s.last = e.time
    stats[k] = s

    if let fh = logFH {
        var lbl = ""
        if let t = djayType(e.kind) { lbl = label(type: t, ch: e.ch, data: e.d1) }
        let line = String(format: "%.4f\t%@\t%d\t%d\t%d\t%d\t%@\n",
                          e.time - start, e.kind.rawValue, e.ch, e.d1, e.d2, e.value, lbl)
        fh.write(line.data(using: .utf8)!)
    }
}

let muted: Set<EventKeyLite> = Set(muteSpec.split(separator: ",").compactMap { part in
    let bits = part.split(separator: ":")
    guard bits.count == 2, let n = Int(bits[1]) else { return nil }
    switch bits[0].lowercased() {
    case "note": return EventKeyLite(isNote: true, d1: n)
    case "cc":   return EventKeyLite(isNote: false, d1: n)
    default:     return nil
    }
})

func handle(_ e: Event) {
    if e.kind == .realtime { return }                        // clock/active-sense noise
    switch e.kind {
    case .noteOn, .noteOff: if muted.contains(EventKeyLite(isNote: true,  d1: e.d1)) { return }
    case .cc:               if muted.contains(EventKeyLite(isNote: false, d1: e.d1)) { return }
    default: break
    }
    record(e)
    if raw || !continuous.contains(e.kind) { flushPending(); emitLine(e, repeats: 1, from: nil); return }

    let k = EventKey(kind: e.kind, ch: e.ch, d1: e.d1)
    if let p = pending, EventKey(kind: p.event.kind, ch: p.event.ch, d1: p.event.d1) == k {
        pending = (e, p.count + 1, p.first)
    } else {
        flushPending()
        pending = (e, 1, e.value)
    }
}

let flushTimer = DispatchSource.makeTimerSource(queue: q)
flushTimer.schedule(deadline: .now() + .milliseconds(150), repeating: .milliseconds(150))
flushTimer.setEventHandler {
    if let p = pending, Date().timeIntervalSince1970 - p.event.time > 0.14 { flushPending() }
}
flushTimer.resume()

func summary() {
    flushPending()
    print("\n" + String(repeating: "─", count: 110))
    print("distinct controls seen: \(stats.count)")
    print(pad("kind", 11) + pad("ch", 5) + pad("address", 10) + pad("count", 8) + pad("value range", 14) + pad("control", 24) + "djay mapping")
    let order: [Kind] = [.noteOn, .noteOff, .cc, .pitch, .poly, .pressure, .program, .sysex, .common]
    for k in stats.keys.sorted(by: {
        let ai = order.firstIndex(of: $0.kind) ?? 99, bi = order.firstIndex(of: $1.kind) ?? 99
        return ai != bi ? ai < bi : ($0.ch != $1.ch ? $0.ch < $1.ch : $0.d1 < $1.d1)
    }) {
        let s = stats[k]!
        var lbl = ""
        if let t = djayType(k.kind) { lbl = label(type: t, ch: k.ch, data: k.d1) }
        let addr: String
        switch k.kind {
        case .noteOn, .noteOff, .poly: addr = "note \(k.d1)"
        case .cc:                      addr = "cc \(k.d1)"
        default:                       addr = "—"
        }
        print(pad(k.kind.rawValue, 11) + pad("ch\(k.ch + 1)", 5) + pad(addr, 10)
              + pad("\(s.count)", 8) + pad("\(s.minV)…\(s.maxV)", 14)
              + pad(primeName(k.kind, k.d1), 24)
              + (lbl.isEmpty ? "· unmapped in djay" : lbl))
    }
    logFH?.closeFile()
    if let lp = logPath { print("\nlog written to \(lp)") }
}

// ───────────────────────────── open the port ─────────────────────────────

let matches = sources().filter { $0.1.localizedCaseInsensitiveContains(portFilter) }
guard let (src, srcName) = matches.first else {
    FileHandle.standardError.write("no MIDI source matching \"\(portFilter)\". try --list\n".data(using: .utf8)!)
    exit(1)
}
if matches.count > 1 { print("note: \(matches.count) sources matched \"\(portFilter)\"; using the first") }

var client = MIDIClientRef()
var inPort = MIDIPortRef()
let parser = Parser()
parser.onEvent = handle

guard MIDIClientCreateWithBlock("midimon" as CFString, &client, nil) == noErr else {
    FileHandle.standardError.write("MIDIClientCreate failed\n".data(using: .utf8)!); exit(1)
}
let portStatus = MIDIInputPortCreateWithBlock(client, "midimon-in" as CFString, &inPort) { pktList, _ in
    let now = Date().timeIntervalSince1970
    var bytes: [UInt8] = []
    for pkt in pktList.unsafeSequence() {
        withUnsafeBytes(of: pkt.pointee.data) { rb in
            for i in 0..<Int(pkt.pointee.length) { bytes.append(rb[i]) }
        }
    }
    q.async { parser.feed(bytes, at: now) }
}
guard portStatus == noErr, MIDIPortConnectSource(inPort, src, nil) == noErr else {
    FileHandle.standardError.write("could not connect to \"\(srcName)\"\n".data(using: .utf8)!); exit(1)
}

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
sigSrc.setEventHandler { summary(); exit(0) }
sigSrc.resume()

setvbuf(stdout, nil, _IOLBF, 0)
print("listening on: \(srcName)")
print(raw ? "mode: raw (no coalescing)" : "mode: continuous streams coalesced — use --raw for every message")
print("touch a control on the deck.  Ctrl-C for a summary.\n")
print(pad("time", 10) + pad("ch", 5) + pad("type", 11) + pad("address", 10) + pad("value", 18) + pad("control", 24) + "djay keyPath")
print(String(repeating: "─", count: 110))

CFRunLoopRun()
