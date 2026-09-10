// screenprobe — read the SC5000M's screen device without touching it.
//
// The 7" panel is a second USB device on the deck's internal hub (0x15E4:0xA00A,
// interface "Denon DJ Remote Screen"): vendor-specific class 255, so no driver
// claims it and no published spec says what it wants. This walks its configuration
// descriptor to show what the endpoints actually are — bulk or isochronous, which
// way they point, how much they carry. That shape is what says whether the panel
// takes a framebuffer, and whether anything streams back.
//
// Reading the descriptor needs no exclusive access, so this cannot disturb the deck.

import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

let VENDOR: UInt16 = 0x15E4
var PRODUCT: UInt16 = 0xA00A

var listenEP = -1           // endpoint address to read, e.g. 0x83
var argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    switch argv[ai] {
    case "-l", "--listen":
        ai += 1
        listenEP = ai < argv.count ? (Int(argv[ai].replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x83) : 0x83
    case "-p", "--product":
        ai += 1
        if ai < argv.count, let v = UInt16(argv[ai].replacingOccurrences(of: "0x", with: ""), radix: 16) { PRODUCT = v }
    case "-h", "--help":
        print("""
        screenprobe — dump the USB endpoints of the SC5000M's screen device

        usage: screenprobe [--product <hex>]
          --product <hex>   USB product id  (default a00a = SC5000M PRIME Screen;
                            800a is the MIDI controller, e00a the internal hub)
          -l, --listen <ep> read an IN endpoint and hex-dump whatever arrives,
                            e.g. --listen 83 for the interrupt pipe that should
                            carry touch. Claims the interface (may need sudo) but
                            still sends the deck nothing.

        With no --listen this is passive: it reads the configuration descriptor only.
        """)
        exit(0)
    default: break
    }
    ai += 1
}

/// The IOKit plug-in UUIDs, which exist only as C macros in IOUSBLib.h.
func uuid(_ b: [UInt8]) -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                   b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
}
let kDeviceUserClientTypeID = uuid([0x9d,0xc7,0xb7,0x80,0x9e,0xc0,0x11,0xD4,
                                    0xa5,0x4f,0x00,0x0a,0x27,0x05,0x28,0x61])
let kPlugInInterfaceID      = uuid([0xC2,0x44,0xE8,0x58,0x10,0x9C,0x11,0xD4,
                                    0x91,0xD4,0x00,0x50,0xE4,0xC6,0x42,0x6F])
let kDeviceInterfaceID      = uuid([0x5c,0x81,0x87,0xd0,0x9e,0xf3,0x11,0xD4,
                                    0x8b,0x45,0x00,0x0a,0x27,0x05,0x28,0x61])
let kInterfaceUserClientTypeID = uuid([0x2d,0x97,0x86,0xc6,0x9e,0xf3,0x11,0xD4,
                                       0xad,0x51,0x00,0x0a,0x27,0x05,0x28,0x61])
let kInterfaceInterfaceID182   = uuid([0x49,0x23,0xac,0x4c,0x48,0x96,0x11,0xD5,
                                       0x92,0x08,0x00,0x0a,0x27,0x80,0x1e,0x86])

func findDevice() -> io_service_t {
    for name in ["IOUSBHostDevice", "IOUSBDevice"] {
        guard let m = IOServiceMatching(name) else { continue }
        let d = m as NSMutableDictionary
        d[kUSBVendorID] = NSNumber(value: VENDOR)
        d[kUSBProductID] = NSNumber(value: PRODUCT)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, d, &iter) == KERN_SUCCESS else { continue }
        let svc = IOIteratorNext(iter)
        IOObjectRelease(iter)
        if svc != 0 { return svc }
    }
    return 0
}

let service = findDevice()
guard service != 0 else {
    FileHandle.standardError.write("no USB device \(String(format: "%04x:%04x", VENDOR, PRODUCT)) — is the deck on and in Computer Mode?\n".data(using: .utf8)!)
    exit(1)
}
defer { IOObjectRelease(service) }

// COM-style plumbing: plug-in for the service, then the device interface from it.
var pluginRef: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
var score: Int32 = 0
guard IOCreatePlugInInterfaceForService(service, kDeviceUserClientTypeID,
                                        kPlugInInterfaceID, &pluginRef, &score) == KERN_SUCCESS,
      let plugin = pluginRef else {
    FileHandle.standardError.write("could not create a plug-in for the device\n".data(using: .utf8)!); exit(1)
}
var devRef: LPVOID?
let iid = CFUUIDGetUUIDBytes(kDeviceInterfaceID)
guard plugin.pointee?.pointee.QueryInterface(plugin, iid, &devRef) == S_OK,
      let raw = devRef else {
    FileHandle.standardError.write("could not query the device interface\n".data(using: .utf8)!); exit(1)
}
_ = plugin.pointee?.pointee.Release(plugin)
let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)


var vend: UInt16 = 0, prod: UInt16 = 0, nConf: UInt8 = 0
_ = dev.pointee?.pointee.GetDeviceVendor(dev, &vend)
_ = dev.pointee?.pointee.GetDeviceProduct(dev, &prod)
_ = dev.pointee?.pointee.GetNumberOfConfigurations(dev, &nConf)

print(String(format: "device   %04x:%04x", vend, prod))
print("configs  \(nConf)")

var cfgPtr: IOUSBConfigurationDescriptorPtr?
guard dev.pointee?.pointee.GetConfigurationDescriptorPtr(dev, 0, &cfgPtr) == KERN_SUCCESS,
      let cfg = cfgPtr else {
    FileHandle.standardError.write("could not read the configuration descriptor\n".data(using: .utf8)!); exit(1)
}

let total = Int(UInt16(cfg.pointee.wTotalLength.littleEndian))
let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(cfg), count: total).map { $0 }
print("descriptor \(total) bytes\n")

func xferName(_ a: UInt8) -> String {
    switch a & 0x03 {
    case 0: return "control"
    case 1: return "isochronous"
    case 2: return "bulk"
    default: return "interrupt"
    }
}

var i = 0
while i + 1 < bytes.count {
    let len = Int(bytes[i]), type = bytes[i + 1]
    if len == 0 { break }
    switch type {
    case 0x04 where i + 8 < bytes.count:                    // interface
        print(String(format: "interface %d  alt %d  class %d/%d/%d  %d endpoints",
                     Int(bytes[i + 2]), Int(bytes[i + 3]), Int(bytes[i + 5]), Int(bytes[i + 6]),
                     Int(bytes[i + 7]), Int(bytes[i + 4])))
    case 0x05 where i + 6 < bytes.count:                    // endpoint
        let addr = bytes[i + 2]
        let mps  = Int(UInt16(bytes[i + 4]) | UInt16(bytes[i + 5]) << 8)
        let dir  = (addr & 0x80) != 0 ? "IN  (device → host)" : "OUT (host → device)"
        print(String(format: "   ep 0x%02x  %-20@ %-12@ %5d bytes/packet  interval %d",
                     Int(addr), dir as NSString, xferName(bytes[i + 3]) as NSString,
                     mps, Int(bytes[i + 6])))
    default: break
    }
    i += len
}

// A rough ceiling for what the panel could be fed, for sizing video against.
let outBulk = stride(from: 0, to: bytes.count - 6, by: 1).compactMap { j -> Int? in
    guard bytes[j + 1] == 0x05, bytes[j] == 7, (bytes[j + 2] & 0x80) == 0,
          (bytes[j + 3] & 0x03) == 2 else { return nil }
    return Int(UInt16(bytes[j + 4]) | UInt16(bytes[j + 5]) << 8)
}
if !outBulk.isEmpty {
    print("\n1280x720 uncompressed RGB565 is 1.8 MB a frame — 55 MB/s at 30fps, which")
    print("USB 2.0 high speed (~40 MB/s usable) cannot carry. Whatever this panel takes")
    print("is therefore compressed, most likely a JPEG per frame.")
}


// ───────────────────────── listening on an IN endpoint ─────────────────────────

// Reading is the safe half of this device: claiming the interface and pulling from an
// IN pipe tells us what the panel reports without ever writing to the bulk pipe that
// drives the pixels. If 0x83 carries touch, that is a decodable foothold in a protocol
// with no published spec.

guard listenEP >= 0 else { exit(0) }

let wantNumber = UInt8(listenEP & 0x0F)

var findReq = IOUSBFindInterfaceRequest(
    bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
    bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
    bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
    bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))

var ifIter: io_iterator_t = 0
guard dev.pointee?.pointee.CreateInterfaceIterator(dev, &findReq, &ifIter) == KERN_SUCCESS else {
    FileHandle.standardError.write("could not iterate interfaces\n".data(using: .utf8)!); exit(1)
}
let ifService = IOIteratorNext(ifIter)
IOObjectRelease(ifIter)
guard ifService != 0 else {
    FileHandle.standardError.write("device exposes no interface\n".data(using: .utf8)!); exit(1)
}

var ifPluginRef: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
var ifScore: Int32 = 0
guard IOCreatePlugInInterfaceForService(ifService, kInterfaceUserClientTypeID,
                                        kPlugInInterfaceID, &ifPluginRef, &ifScore) == KERN_SUCCESS,
      let ifPlugin = ifPluginRef else {
    FileHandle.standardError.write("could not create an interface plug-in\n".data(using: .utf8)!); exit(1)
}
var ifRef: LPVOID?
guard ifPlugin.pointee?.pointee.QueryInterface(ifPlugin, CFUUIDGetUUIDBytes(kInterfaceInterfaceID182), &ifRef) == S_OK,
      let ifRaw = ifRef else {
    FileHandle.standardError.write("could not query the interface\n".data(using: .utf8)!); exit(1)
}
_ = ifPlugin.pointee?.pointee.Release(ifPlugin)
let intf = ifRaw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBInterfaceInterface182>?.self)

let opened = intf.pointee?.pointee.USBInterfaceOpen(intf) ?? -1
guard opened == KERN_SUCCESS else {
    let why = opened == kIOReturnExclusiveAccess
        ? "another process already holds it"
        : String(format: "IOReturn 0x%08x — try running with sudo", opened)
    FileHandle.standardError.write("could not claim the interface: \(why)\n".data(using: .utf8)!)
    exit(1)
}
defer { _ = intf.pointee?.pointee.USBInterfaceClose(intf) }

// Pipes are numbered from 1 in the order the endpoints appear; map ours by address.
var nPipes: UInt8 = 0
_ = intf.pointee?.pointee.GetNumEndpoints(intf, &nPipes)
var pipeRef: UInt8 = 0
var pipeMax = 0
var pipeType: UInt8 = 0
for p in 1...max(nPipes, 1) {
    var dir: UInt8 = 0, num: UInt8 = 0, tt: UInt8 = 0, interval: UInt8 = 0
    var mps: UInt16 = 0
    guard intf.pointee?.pointee.GetPipeProperties(intf, p, &dir, &num, &tt, &mps, &interval) == KERN_SUCCESS
    else { continue }
    if num == wantNumber, dir == 1 { pipeRef = p; pipeMax = Int(mps); pipeType = tt }
}
guard pipeRef != 0 else {
    FileHandle.standardError.write(String(format: "no IN endpoint 0x%02x on this interface\n", listenEP).data(using: .utf8)!)
    exit(1)
}

let isInterrupt = pipeType == 3
print(String(format: "\nlistening on endpoint 0x%02x  (pipe %d, %@, %d bytes/packet)",
             listenEP, Int(pipeRef), (isInterrupt ? "interrupt" : "bulk") as NSString, pipeMax))
print("touch the screen — Ctrl-C to stop.  Nothing is sent to the deck.\n")
setvbuf(stdout, nil, _IOLBF, 0)

// IOUSBLib's error codes are C macros; a read that simply saw no traffic in the
// timeout window is not a failure, so name the two that mean "nothing yet".
let usbTransactionTimeout: IOReturn = -536854447   // 0xe0004051
let ioTimeout: IOReturn             = -536870190   // 0xe00002d6

var packets = 0
let start = Date()
var buf = [UInt8](repeating: 0, count: max(pipeMax, 64))
while true {
    var size = UInt32(buf.count)
    // Timeouts are a bulk-pipe feature; asking for one on an interrupt pipe is
    // rejected outright, so those read blocking and wait for the deck to say something.
    let r = buf.withUnsafeMutableBytes { p -> IOReturn in
        isInterrupt
            ? (intf.pointee?.pointee.ReadPipe(intf, pipeRef, p.baseAddress, &size) ?? -1)
            : (intf.pointee?.pointee.ReadPipeTO(intf, pipeRef, p.baseAddress, &size, 50, 1000) ?? -1)
    }
    if r == usbTransactionTimeout || r == ioTimeout { continue }
    guard r == KERN_SUCCESS else {
        print(String(format: "read stopped: IOReturn 0x%08x", r)); break
    }
    guard size > 0 else { continue }
    packets += 1
    let hex = buf.prefix(Int(size)).map { String(format: "%02x", $0) }.joined(separator: " ")
    print(String(format: "%8.3f  %2d bytes  %@", Date().timeIntervalSince(start), Int(size), hex))
}
