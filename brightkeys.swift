// brightkeys — brightness keys control whichever display the mouse is on.
//
// Built-in display: the key event passes through untouched (macOS handles it).
// External display: the key event is swallowed and a DDC/CI luminance command
// is sent over the display's I2C channel instead.
//
// DDC transport approach (IOAVService over DCPAVServiceProxy) follows m1ddc:
// https://github.com/waydabber/m1ddc (MIT)

import AppKit
import CoreGraphics
import IOKit

// MARK: - Private APIs

typealias IOAVServiceRef = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVServiceRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVServiceRef, _ chipAddress: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVServiceRef, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
func CoreDisplay_DisplayCreateInfoDictionary(_ display: CGDirectDisplayID) -> Unmanaged<CFDictionary>?

// MARK: - Config

let stepCount = 16              // same number of steps as the built-in display
let chipDefault: UInt32 = 0x37  // standard DDC/CI chip address
let chipMCDP29xx: UInt32 = 0xB7 // some USB-C/TB bridges route DDC here
let ddcHostAddress: UInt32 = 0x51
let vcpLuminance: UInt8 = 0x10
let cacheTTL: TimeInterval = 10 // re-read the monitor if idle this long (OSD changes)

func log(_ s: String) {
    FileHandle.standardError.write("brightkeys: \(s)\n".data(using: .utf8)!)
}

// MARK: - DDC

struct DDCTransport {
    let service: IOAVServiceRef
    let chip: UInt32
}

enum DDC {
    static func write(_ t: DDCTransport, _ bytes: [UInt8]) -> Bool {
        var buf = bytes
        // Displays sometimes drop a single write; m1ddc sends twice.
        for _ in 0..<2 {
            usleep(10_000)
            if IOAVServiceWriteI2C(t.service, t.chip, ddcHostAddress, &buf, UInt32(buf.count)) != kIOReturnSuccess {
                return false
            }
        }
        return true
    }

    /// Returns (current, max) for a VCP code, or nil on failure.
    static func read(_ t: DDCTransport, _ code: UInt8) -> (cur: Int, max: Int)? {
        for _ in 0..<3 {
            var req: [UInt8] = [0x82, 0x01, code, 0]
            req[3] = 0x6E ^ req[0] ^ req[1] ^ req[2]
            guard write(t, req) else { continue }

            usleep(t.chip == chipMCDP29xx ? 50_000 : 10_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard IOAVServiceReadI2C(t.service, t.chip, ddcHostAddress, &reply, 12) == kIOReturnSuccess else { continue }

            // Get VCP Feature Reply: [.., .., .., result, vcp, type, maxH, maxL, curH, curL, chk]
            guard reply[3] == 0, reply[4] == code else { continue }
            let max = Int(reply[6]) << 8 | Int(reply[7])
            let cur = Int(reply[8]) << 8 | Int(reply[9])
            if max > 0 { return (cur, max) }
        }
        return nil
    }

    static func set(_ t: DDCTransport, _ code: UInt8, _ value: Int) -> Bool {
        var cmd: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        cmd[5] = UInt8(0x6E ^ ddcHostAddress) ^ cmd[0] ^ cmd[1] ^ cmd[2] ^ cmd[3] ^ cmd[4]
        return write(t, cmd)
    }
}

// MARK: - Display → DDC transport lookup

func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
    IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                    IOOptionBits(kIORegistryIterateRecursively)) as? String
}

func isMCDP29xx(_ proxy: io_service_t) -> Bool {
    var parent: io_registry_entry_t = 0
    guard IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
    defer { IOObjectRelease(parent) }
    let cls = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
    return cls == "AppleDCPMCDP29XX"
}

/// Finds the DCPAVServiceProxy belonging to a display's framebuffer. In the
/// IOService plane the proxy follows its IOMobileFramebuffer during recursive
/// iteration, so we track the most recent framebuffer and match on its ID.
func findTransport(for display: CGDirectDisplayID) -> DDCTransport? {
    guard let info = CoreDisplay_DisplayCreateInfoDictionary(display)?.takeRetainedValue() as? [String: Any],
          let location = info["IODisplayLocation"] as? String else { return nil }

    let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
    guard adapter != 0 else { return nil }
    defer { IOObjectRelease(adapter) }
    var adapterID: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else { return nil }

    var iter: io_iterator_t = 0
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iter) }

    var inMatchingFramebuffer = false
    while case let service = IOIteratorNext(iter), service != 0 {
        defer { IOObjectRelease(service) }

        if IOObjectConformsTo(service, "IOMobileFramebuffer") != 0 {
            var id: UInt64 = 0
            inMatchingFramebuffer = IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS && id == adapterID
            continue
        }
        guard inMatchingFramebuffer else { continue }

        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &name)
        guard String(cString: name) == "DCPAVServiceProxy",
              registryString(service, "Location") == "External",
              let av = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
        else { continue }

        return DDCTransport(service: av, chip: isMCDP29xx(service) ? chipMCDP29xx : chipDefault)
    }
    return nil
}

// MARK: - Brightness state

final class ExternalBrightness {
    private let queue = DispatchQueue(label: "brightkeys.ddc")
    private var transports: [CGDirectDisplayID: DDCTransport] = [:]
    private var cache: [CGDirectDisplayID: (cur: Int, max: Int, at: Date)] = [:]

    /// Called on display hot-plug / reconfiguration.
    func invalidate() {
        queue.async { self.transports.removeAll(); self.cache.removeAll() }
    }

    func step(_ display: CGDirectDisplayID, up: Bool) {
        // DDC round-trips take tens of ms; never block the event tap.
        queue.async {
            guard let t = self.transport(display) else { log("no DDC transport for display \(display)"); return }

            var state = self.cache[display]
            if state == nil || Date().timeIntervalSince(state!.at) > cacheTTL {
                guard let v = DDC.read(t, vcpLuminance) else {
                    log("DDC read failed for display \(display)")
                    self.transports[display] = nil
                    return
                }
                state = (v.cur, v.max, Date())
            }
            guard let s = state else { return }

            // Snap to the step grid so up/down are symmetric, like the built-in display.
            let stepSize = Double(s.max) / Double(stepCount)
            let currentStep = (Double(s.cur) / stepSize).rounded()
            let target = Int(((currentStep + (up ? 1 : -1)) * stepSize).rounded())
            let next = min(max(target, 0), s.max)

            if DDC.set(t, vcpLuminance, next) {
                self.cache[display] = (next, s.max, Date())
            } else {
                log("DDC write failed for display \(display)")
                self.transports[display] = nil
                self.cache[display] = nil
            }
        }
    }

    private func transport(_ display: CGDirectDisplayID) -> DDCTransport? {
        if let t = transports[display] { return t }
        let t = findTransport(for: display)
        transports[display] = t
        return t
    }
}

// MARK: - Event tap

let NX_SYSDEFINED: UInt32 = 14
let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
let NX_KEYTYPE_BRIGHTNESS_UP = 2
let NX_KEYTYPE_BRIGHTNESS_DOWN = 3

let brightness = ExternalBrightness()
var eventTap: CFMachPort?

func displayUnderMouse() -> CGDirectDisplayID? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return nil }
    return display
}

let tapCallback: CGEventTapCallBack = { _, type, cgEvent, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(cgEvent)
    }

    guard type.rawValue == NX_SYSDEFINED,
          let event = NSEvent(cgEvent: cgEvent),
          event.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else {
        return Unmanaged.passUnretained(cgEvent)
    }

    let keyCode = (event.data1 & 0xFFFF_0000) >> 16
    guard keyCode == NX_KEYTYPE_BRIGHTNESS_UP || keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN,
          let display = displayUnderMouse(),
          CGDisplayIsBuiltin(display) == 0 else {
        return Unmanaged.passUnretained(cgEvent)
    }

    // Act on key-down (including auto-repeat); swallow both down and up.
    let keyState = (event.data1 & 0xFF00) >> 8
    if keyState == 0x0A {
        brightness.step(display, up: keyCode == NX_KEYTYPE_BRIGHTNESS_UP)
    }
    return nil
}

// MARK: - Main

// `brightkeys --probe`: read-only check that each external display answers DDC.
if CommandLine.arguments.dropFirst().first == "--probe" {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(8, &ids, &count)
    for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
        guard let t = findTransport(for: id) else { print("display \(id): no DDC transport"); continue }
        let chip = String(t.chip, radix: 16)
        if let v = DDC.read(t, vcpLuminance) {
            print("display \(id): luminance \(v.cur)/\(v.max) (chip 0x\(chip))")
        } else {
            print("display \(id): DDC read failed (chip 0x\(chip))")
        }
    }
    exit(0)
}

// Swallowing events needs Accessibility. The trust check is cached for the
// life of the process, so polling never sees a later grant. Exit instead and
// let launchd (KeepAlive + ThrottleInterval) relaunch us to re-check.
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    log("no Accessibility permission yet (System Settings → Privacy & Security → Accessibility); retrying in 10s")
    exit(1)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
                                  callback: tapCallback,
                                  userInfo: nil) else {
    log("failed to create event tap")
    exit(1)
}
eventTap = tap

CGDisplayRegisterReconfigurationCallback({ _, _, _ in brightness.invalidate() }, nil)

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("running")
CFRunLoopRun()
