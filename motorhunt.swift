import CoreMIDI
import Foundation

// Find which CC drives the SC5000M platter motor: poke a CC, then listen for the
// deck reporting rotation (it streams jog data while the platter turns).

var portFilter = "SC5000M Prime Controller"
var lo = 0, hi = 127
var pokeValue = 127
var listen = 0.6
var settle = 0.35
var threshold = 8
var charCC = -1
var probe = ""

var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    func next() -> String? { ai += 1; return ai < argv.count ? argv[ai] : nil }
    switch argv[ai] {
    case "--from":      lo = Int(next() ?? "") ?? lo
    case "--to":        hi = Int(next() ?? "") ?? hi
    case "--value":     pokeValue = Int(next() ?? "") ?? pokeValue
    case "--listen":    listen = Double(next() ?? "") ?? listen
    case "--settle":    settle = Double(next() ?? "") ?? settle
    case "--threshold": threshold = Int(next() ?? "") ?? threshold
    case "--values":    charCC = Int(next() ?? "") ?? charCC
    case "--probe":     probe = next() ?? ""
    case "-p", "--port": portFilter = next() ?? portFilter
    case "-h", "--help":
        print("""
        motorhunt — find the CC that spins the platter

        Sends each CC in turn, then listens for the deck reporting rotation.
        Ignores the note-56 heartbeat.

          --from <n> --to <n>   CC range to sweep    (default 0-127)
          --value <n>           value to poke with   (default 127)
          --listen <s>          listen window        (default 0.6)
          --settle <s>          gap between pokes, to let the platter stop (default 0.35)
          --threshold <n>       events that count as motion (default 8)
          --values <cc>         sweep VALUES on one CC: speed and direction
          --probe <seq>         run a sequence, e.g. --probe 66:0,65:127,68:0
        """)
        exit(0)
    default: FileHandle.standardError.write("unknown option\n".data(using: .utf8)!); exit(2)
    }
    ai += 1
}

func strProp(_ o: MIDIObjectRef, _ p: CFString) -> String {
    var out: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(o, p, &out) == noErr, let out else { return "" }
    return out.takeRetainedValue() as String
}

let srcs = (0..<MIDIGetNumberOfSources()).map { MIDIGetSource($0) }
    .filter { strProp($0, kMIDIPropertyDisplayName).localizedCaseInsensitiveContains(portFilter) }
let dsts = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }
    .filter { strProp($0, kMIDIPropertyDisplayName).localizedCaseInsensitiveContains(portFilter) }
guard let src = srcs.first, let dst = dsts.first else {
    FileHandle.standardError.write("could not find \"\(portFilter)\" in+out\n".data(using: .utf8)!); exit(1)
}

var client = MIDIClientRef(); var inPort = MIDIPortRef(); var outPort = MIDIPortRef()
MIDIClientCreateWithBlock("motorhunt" as CFString, &client, nil)
MIDIOutputPortCreate(client, "motorhunt-out" as CFString, &outPort)

let lock = NSLock()
var motion = 0
var seen: [Int: Int] = [:]          // controller number -> count, for the active poke
var jogSum = 0                      // signed relative jog delta, for direction
var jogN = 0

MIDIInputPortCreateWithBlock(client, "motorhunt-in" as CFString, &inPort) { pktList, _ in
    for pkt in pktList.unsafeSequence() {
        withUnsafeBytes(of: pkt.pointee.data) { rb in
            var i = 0
            let n = Int(pkt.pointee.length)
            while i < n {
                let b = rb[i]
                if b == 0x90 && i + 2 < n && rb[i + 1] == 56 { i += 3; continue }   // heartbeat
                if b >= 0x80 && b < 0xF0 {
                    let size = ((b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0) ? 2 : 3
                    lock.lock()
                    motion += 1
                    if (b & 0xF0) == 0xB0 && i + 2 < n {
                        let ctrl = Int(rb[i + 1])
                        seen[ctrl, default: 0] += 1
                        if ctrl == 55 || ctrl == 54 {
                            let v = Int(rb[i + 2])
                            jogSum += v >= 64 ? v - 128 : v
                            jogN += 1
                        }
                    }
                    lock.unlock()
                    i += size
                } else { i += 1 }
            }
        }
    }
}
MIDIPortConnectSource(inPort, src, nil)

func send(_ m: [UInt8]) {
    let size = 512
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { raw.deallocate() }
    let pl = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
    let cur = MIDIPacketListInit(pl)
    _ = MIDIPacketListAdd(pl, size, cur, 0, m.count, m)
    MIDISend(outPort, dst, UnsafePointer(pl))
}

setvbuf(stdout, nil, _IOLBF, 0)
print("device   : \(strProp(src, kMIDIPropertyDisplayName))")
print("sweeping : CC \(lo)-\(hi) at value \(pokeValue), \(listen)s listen window")
print("hands off the platter — motion must come from the motor\n")

Thread.sleep(forTimeInterval: 1.0)

if !probe.isEmpty {
    print("probe sequence — motion measured after each command\n")
    print("  command      events   jog sum   state")
    for step in probe.split(separator: ",") {
        let bits = step.split(separator: ":")
        guard bits.count == 2, let c = Int(bits[0]), let v = Int(bits[1]) else { continue }
        lock.lock(); motion = 0; jogSum = 0; lock.unlock()
        send([0xB0, UInt8(c), UInt8(v)])
        Thread.sleep(forTimeInterval: listen)
        lock.lock(); let m = motion; let js = jogSum; lock.unlock()
        let state = m < threshold ? "STOPPED" : (js > 20 ? "spinning forward" : (js < -20 ? "spinning REVERSE" : "moving, no net travel"))
        print(String(format: "  CC %-3d = %-3d  %6d   %7d   %@", c, v, m, js, state))
        Thread.sleep(forTimeInterval: settle)
    }
    print("\ndone")
    exit(0)
}

if charCC >= 0 {
    print("value sweep on CC \(charCC) — event count is speed, sign is direction\n")
    print("  value   events   jog sum   direction")
    for v in [0, 1, 2, 4, 8, 16, 32, 48, 63, 64, 65, 80, 96, 112, 126, 127] {
        lock.lock(); motion = 0; seen = [:]; jogSum = 0; jogN = 0; lock.unlock()
        send([0xB0, UInt8(charCC), UInt8(v)])
        Thread.sleep(forTimeInterval: listen)
        lock.lock(); let m = motion; let js = jogSum; lock.unlock()
        send([0xB0, UInt8(charCC), 0])
        Thread.sleep(forTimeInterval: settle)
        let dir = js > 20 ? "forward" : (js < -20 ? "REVERSE" : (m > threshold ? "(no net travel)" : "-"))
        print(String(format: "  %5d   %6d   %7d   %@", v, m, js, dir))
    }
    print("\ndone")
    exit(0)
}

var hits: [(Int, Int, [Int: Int])] = []

for cc in lo...hi {
    lock.lock(); motion = 0; seen = [:]; lock.unlock()
    send([0xB0, UInt8(cc), UInt8(pokeValue)])
    Thread.sleep(forTimeInterval: listen)
    lock.lock(); let m = motion; let s = seen; lock.unlock()
    send([0xB0, UInt8(cc), 0])
    Thread.sleep(forTimeInterval: settle)

    if m >= threshold {
        let detail = s.sorted { $0.key < $1.key }.map { "cc\($0.key)×\($0.value)" }.joined(separator: " ")
        print("  ** CC \(cc)  ->  \(m) events   \(detail)")
        hits.append((cc, m, s))
    }
}

print("\n" + String(repeating: "─", count: 60))
if hits.isEmpty {
    print("no CC produced motion above threshold \(threshold)")
} else {
    print("controllers that moved the platter:")
    for (cc, m, _) in hits.sorted(by: { $0.1 > $1.1 }) { print("  CC \(cc)   \(m) events") }
}
