// avedid — install a virtual EDID on an Apple Silicon display at runtime.
//
// macOS on Apple Silicon ignores the IODisplayEDID key in /Library/Displays
// overrides; the DCP builds the mode list from the panel's real EDID. The only
// way to hand it a different one is IOAVServiceSetVirtualEDIDMode, a private
// IOKit call. This is what SwitchResX's daemon does.
//
// The override is runtime state, not a file: it is gone after a reboot.
//
//   swiftc -O -o build/avedid avedid.swift
//
//   ./build/avedid list
//   ./build/avedid apply build/patched.bin
//   ./build/avedid revert

import AppKit
import CoreFoundation
import CoreGraphics
import Foundation
import IOKit

// MARK: - Private IOKit / SkyLight

typealias IOAVServiceRef = CFTypeRef

private let ioKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
private let skyLightHandle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private func sym(_ handle: UnsafeMutableRawPointer?, _ name: String) -> UnsafeMutableRawPointer? {
    guard let handle else { return nil }
    return dlsym(handle, name)
}

private typealias CreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias CopyEDIDFn =
    @convention(c) (IOAVServiceRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
private typealias SetVirtualEDIDModeFn =
    @convention(c) (IOAVServiceRef, Int32, CFData?) -> IOReturn
private typealias ReadI2CFn =
    @convention(c) (IOAVServiceRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias DetectDisplaysFn = @convention(c) () -> Void

private let ioavServiceCreateWithService = sym(ioKitHandle, "IOAVServiceCreateWithService")
    .map { unsafeBitCast($0, to: CreateWithServiceFn.self) }
private let ioavServiceCopyEDID = sym(ioKitHandle, "IOAVServiceCopyEDID")
    .map { unsafeBitCast($0, to: CopyEDIDFn.self) }
private let ioavServiceSetVirtualEDIDMode = sym(ioKitHandle, "IOAVServiceSetVirtualEDIDMode")
    .map { unsafeBitCast($0, to: SetVirtualEDIDModeFn.self) }
private let ioavServiceReadI2C = sym(ioKitHandle, "IOAVServiceReadI2C")
    .map { unsafeBitCast($0, to: ReadI2CFn.self) }
private let slsDetectDisplays = sym(skyLightHandle, "SLSDetectDisplays")
    .map { unsafeBitCast($0, to: DetectDisplaysFn.self) }

/// SLSIsDisplayModeVRR(displayID, modeID) -> Bool. Two 32-bit args, per the call
/// site in SwitchResX's daemon. Used only to label `modes` output.
private typealias IsModeVRRFn = @convention(c) (CGDirectDisplayID, Int32) -> Bool
private let slsIsDisplayModeVRR = sym(skyLightHandle, "SLSIsDisplayModeVRR")
    .map { unsafeBitCast($0, to: IsModeVRRFn.self) }

func modeIsVRR(_ displayID: CGDirectDisplayID, _ modeID: Int32) -> Bool? {
    guard let fn = slsIsDisplayModeVRR else { return nil }
    return fn(displayID, modeID)
}

private func ioReturnName(_ r: IOReturn) -> String {
    switch UInt32(bitPattern: r) {
    case 0: return "success"
    case 0xe00002c0: return "kIOReturnNoDevice"
    case 0xe00002c1: return "kIOReturnNotPrivileged (try sudo)"
    case 0xe00002c2: return "kIOReturnBadArgument"
    case 0xe00002c7: return "kIOReturnUnsupported"
    case 0xe00002bc: return "kIOReturnError"
    case 0xe00002cd: return "kIOReturnNotOpen"
    case 0xe00002f0: return "kIOReturnNotFound"
    default: return String(format: "0x%08x", UInt32(bitPattern: r))
    }
}

// MARK: - EDID

struct EDID {
    let bytes: [UInt8]

    static let header: [UInt8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]

    var blockCount: Int { bytes.count / 128 }

    /// Bytes 8-9, big-endian, three 5-bit letters.
    var manufacturer: String {
        guard bytes.count >= 10 else { return "??" }
        let v = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        let letters = [(v >> 10) & 0x1f, (v >> 5) & 0x1f, v & 0x1f]
        return String(letters.map { Character(UnicodeScalar(UInt8(0x40 + $0))) })
    }

    /// Bytes 8-9 as a raw vendor number, matching CGDisplayVendorNumber.
    var vendorID: UInt32 {
        guard bytes.count >= 10 else { return 0 }
        return UInt32(bytes[8]) << 8 | UInt32(bytes[9])
    }

    /// Bytes 10-11, little-endian, matching CGDisplayModelNumber.
    var productID: UInt32 {
        guard bytes.count >= 12 else { return 0 }
        return UInt32(bytes[11]) << 8 | UInt32(bytes[10])
    }

    /// Bytes 12-15, little-endian.
    var serial: UInt32 {
        guard bytes.count >= 16 else { return 0 }
        return UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16
            | UInt32(bytes[15]) << 24
    }

    var describedName: String {
        "\(manufacturer) 0x\(String(format: "%04x", productID)) "
            + "(\(blockCount) block\(blockCount == 1 ? "" : "s"), \(bytes.count) bytes)"
    }

    /// Structural checks. Refuses to hand macOS something malformed.
    func validate() -> [String] {
        var problems: [String] = []

        if bytes.count % 128 != 0 || bytes.isEmpty {
            problems.append("length \(bytes.count) is not a non-zero multiple of 128")
            return problems  // everything below assumes whole blocks
        }
        if Array(bytes.prefix(8)) != EDID.header {
            problems.append("missing the 00 FF FF FF FF FF FF 00 base-block header")
        }
        for block in 0..<blockCount {
            let slice = bytes[(block * 128)..<((block + 1) * 128)]
            let sum = slice.reduce(0) { ($0 + Int($1)) & 0xff }
            if sum != 0 {
                problems.append("block \(block) checksum is \(sum), expected 0")
            }
        }
        let declared = Int(bytes[126])
        if declared != blockCount - 1 {
            problems.append(
                "base block declares \(declared) extension block(s) at byte 126, "
                    + "but the file has \(blockCount - 1)")
        }
        return problems
    }
}

// MARK: - AV service discovery

struct AVDisplay {
    let index: Int
    let service: IOAVServiceRef
    let entryID: UInt64
    let edid: EDID?
    /// The CGDirectDisplayID this AV service appears to belong to, if matched.
    let displayID: CGDirectDisplayID?

    var label: String {
        var parts = ["[\(index)] IORegistry entry 0x\(String(format: "%llx", entryID))"]
        if let edid { parts.append(edid.describedName) }
        if let displayID { parts.append("CGDisplay \(displayID)") }
        return parts.joined(separator: "  ")
    }
}

private func readEDID(_ service: IOAVServiceRef) -> EDID? {
    if let copyEDID = ioavServiceCopyEDID {
        var out: Unmanaged<CFData>?
        let r = copyEDID(service, &out)
        if r == kIOReturnSuccess, let data = out?.takeRetainedValue() as Data? {
            return EDID(bytes: [UInt8](data))
        }
    }
    // Fall back to a raw DDC/CI read of the EDID EEPROM at 0x50, the way
    // SwitchResX does when IOAVServiceCopyEDID is unavailable.
    guard let readI2C = ioavServiceReadI2C else { return nil }
    var buffer = [UInt8](repeating: 0, count: 512)
    let r = buffer.withUnsafeMutableBytes { raw -> IOReturn in
        readI2C(service, 0x50, 0, raw.baseAddress!, UInt32(raw.count))
    }
    guard r == kIOReturnSuccess, Array(buffer.prefix(8)) == EDID.header else { return nil }
    let blocks = 1 + Int(buffer[126])
    return EDID(bytes: Array(buffer.prefix(min(blocks * 128, buffer.count))))
}

/// Every online CGDirectDisplayID, keyed by (vendor, model, serial).
private func onlineDisplayIndex() -> [String: CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)

    var map: [String: CGDirectDisplayID] = [:]
    for id in ids.prefix(Int(count)) {
        let key = "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))"
        map[key] = id
    }
    return map
}

func discoverDisplays() -> [AVDisplay] {
    guard let create = ioavServiceCreateWithService else {
        fail("IOAVServiceCreateWithService is not available in this IOKit.")
    }

    var iterator: io_iterator_t = 0
    let matching = IOServiceMatching("DCPAVServiceProxy")
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        == kIOReturnSuccess
    else {
        fail("IOServiceGetMatchingServices(DCPAVServiceProxy) failed.")
    }
    defer { IOObjectRelease(iterator) }

    let displays = onlineDisplayIndex()
    var results: [AVDisplay] = []

    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }

        // Built-in panels expose a service too; only external ones are ours.
        let location = IORegistryEntryCreateCFProperty(
            entry, "Location" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        guard location == "External" else { continue }

        guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
            continue
        }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &entryID)

        let edid = readEDID(service)
        let displayID = edid.flatMap { displays["\($0.vendorID):\($0.productID)"] }

        results.append(
            AVDisplay(
                index: results.count, service: service, entryID: entryID, edid: edid,
                displayID: displayID))
    }
    return results
}

// MARK: - Actions

func setVirtualEDID(_ display: AVDisplay, data: Data?) -> IOReturn {
    guard let setMode = ioavServiceSetVirtualEDIDMode else {
        fail("IOAVServiceSetVirtualEDIDMode is not available in this IOKit.")
    }
    if let data {
        return setMode(display.service, 1, data as CFData)
    }
    return setMode(display.service, 0, nil)
}

/// True if Shift or Option is down. The launch agent uses this as an escape
/// hatch: hold either at login and a timing that blacks out the display is
/// skipped, so a bad EDID can never become a boot loop.
func escapeModifiersHeld() -> Bool {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    return flags.contains(.maskShift) || flags.contains(.maskAlternate)
}

func redetectDisplays() {
    guard let detect = slsDetectDisplays else {
        print("note: SLSDetectDisplays unavailable; you may need to sleep/wake the display.")
        return
    }
    detect()
}

/// `CGDisplayRegisterReconfigurationCallback` takes a bare C function pointer
/// with no usable context argument, so the handler has to live out here.
var reconfigureHook: (() -> Void)?

// MARK: - Refresh rate

/// Put `displayID` back on `hz` without changing its resolution.
///
/// After the panel's real EDID comes back on wake, macOS re-enumerates and
/// drops to a stock rate. Reinstalling the virtual EDID makes the custom mode
/// available again but does not reselect it, so this does. Matching on the
/// current width/height rather than a fixed resolution keeps whatever scaled
/// HiDPI mode is in use intact.
/// All modes matching the display's current resolution, in both points and
/// pixels — i.e. the set that differs only in refresh rate.
func modesAtCurrentResolution(_ displayID: CGDirectDisplayID) -> (CGDisplayMode, [CGDisplayMode])? {
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else {
        return (current, [])
    }
    return (
        current,
        modes.filter {
            $0.width == current.width && $0.height == current.height
                && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
        }
    )
}

/// `tolerance` matters when probing: clock-ladder rungs can sit ~0.2 Hz apart,
/// so the default 0.5 Hz would pick an arbitrary neighbour. The nearest
/// candidate within tolerance wins.
func restoreRefreshRate(_ displayID: CGDirectDisplayID, hz: Double, tolerance: Double = 0.5)
    -> String
{
    guard let (current, candidates) = modesAtCurrentResolution(displayID) else {
        return "could not read the current mode"
    }
    if abs(current.refreshRate - hz) < min(tolerance, 0.01) {
        return String(format: "already at %.4f Hz", current.refreshRate)
    }

    // Each injected timing surfaces twice, as a VRR and a non-VRR variant at the
    // same rate, so nearest-rate alone is ambiguous. Break ties on the lowest
    // mode ID for reproducibility, and report which one was used — a rung that
    // fails as one variant may well lock as the other. Use --mode-id to pin it.
    let matches =
        candidates
        .filter { abs($0.refreshRate - hz) < tolerance }
        .sorted {
            let (da, db) = (abs($0.refreshRate - hz), abs($1.refreshRate - hz))
            return da == db ? $0.ioDisplayModeID < $1.ioDisplayModeID : da < db
        }
    guard let wanted = matches.first else {
        return String(
            format: "no %dx%d mode within %.2f Hz of %.4f Hz is offered",
            current.width, current.height, tolerance, hz)
    }
    let ambiguity =
        matches.count > 1
        ? " (of \(matches.count) matches: "
            + matches.map { "\($0.ioDisplayModeID)" }.joined(separator: ",") + ")"
        : ""
    if wanted.ioDisplayModeID == current.ioDisplayModeID {
        return String(format: "already at %.4f Hz", current.refreshRate)
    }

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        return "CGBeginDisplayConfiguration failed"
    }
    CGConfigureDisplayWithDisplayMode(config, displayID, wanted, nil)
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        return "CGCompleteDisplayConfiguration failed"
    }
    return String(
        format: "set %.4f Hz -> %.4f Hz via modeID %d%@",
        current.refreshRate, wanted.refreshRate, wanted.ioDisplayModeID, ambiguity)
}

/// Select an exact mode by the ID `avedid modes` prints — the unambiguous way to
/// test one specific variant when a rate has several.
func selectModeID(_ displayID: CGDirectDisplayID, modeID: Int32) -> String {
    guard let (current, candidates) = modesAtCurrentResolution(displayID) else {
        return "could not read the current mode"
    }
    guard let wanted = candidates.first(where: { $0.ioDisplayModeID == modeID }) else {
        return "no mode with ID \(modeID) at the current resolution; run `avedid modes`"
    }
    if wanted.ioDisplayModeID == current.ioDisplayModeID {
        return String(format: "already on modeID %d (%.4f Hz)", modeID, current.refreshRate)
    }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        return "CGBeginDisplayConfiguration failed"
    }
    CGConfigureDisplayWithDisplayMode(config, displayID, wanted, nil)
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        return "CGCompleteDisplayConfiguration failed"
    }
    return String(
        format: "set %.4f Hz -> %.4f Hz via modeID %d",
        current.refreshRate, wanted.refreshRate, modeID)
}

// MARK: - CLI

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

let usage = """
    usage: avedid <command> [options]

    commands:
      list                     show every external display and its current EDID
      dump                     print the EDID a display reports, as hex
      modes                    list refresh rates offered at the current resolution
      set-hz <N>               switch to the mode nearest N Hz (exact, for probing
                               ladders whose rungs sit a fraction of a Hz apart)
      set-hz --mode-id <N>     switch to exactly the mode ID `modes` printed, for
                               when one rate has several variants (VRR / non-VRR)
      apply <edid.bin>         install <edid.bin> as a virtual EDID
      revert                   restore the panel's real EDID
      watch <edid.bin>         stay resident and reinstall it whenever the panel
                               drops back to its real EDID (sleep/wake, hot-plug)

    options:
      --index N                act on one display only (default: the display the
                               EDID identifies; apply refuses to guess, revert
                               falls back to all since disabling is harmless)
      --all                    act on every external display
      --yes                    do not prompt for confirmation
      --dry-run                say what would happen, change nothing
      --no-redetect            skip the SLSDetectDisplays call afterwards
      --skip-if-modifiers      do nothing if Shift or Option is held (escape
                               hatch for the launch agent)
      --delay N                wait N seconds first, to let the display finish
                               enumerating after login
      --restore-hz N           after reinstalling, reselect an N Hz mode at the
                               current resolution (watch only)
      --poll N                 safety re-check every N seconds (watch only,
                               default 30; events drive the fast path)

    A virtual EDID is runtime state. Nothing is written to disk, and a reboot
    always restores the panel's real EDID.
    """

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { print(usage); exit(0) }
arguments.removeFirst()

func takeFlag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}

func takeOption(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { fail("\(name) needs a value") }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

let wantsAll = takeFlag("--all")
let assumeYes = takeFlag("--yes")
let dryRun = takeFlag("--dry-run")
let noRedetect = takeFlag("--no-redetect")
let skipIfModifiers = takeFlag("--skip-if-modifiers")
let indexOption: Int? = takeOption("--index").map {
    guard let n = Int($0) else { fail("--index needs a number") }
    return n
}
let delaySeconds: Double? = takeOption("--delay").map {
    guard let n = Double($0), n >= 0 else { fail("--delay needs a non-negative number") }
    return n
}
let restoreHz: Double? = takeOption("--restore-hz").map {
    guard let n = Double($0), n > 0 else { fail("--restore-hz needs a positive number") }
    return n
}
let modeIDOption: Int32? = takeOption("--mode-id").map {
    guard let n = Int32($0) else { fail("--mode-id needs a number") }
    return n
}
let pollInterval: Double = takeOption("--poll").map {
    guard let n = Double($0), n >= 1 else { fail("--poll needs a number >= 1") }
    return n
} ?? 30

if let unknown = arguments.first(where: { $0.hasPrefix("--") }) {
    fail("unknown option \(unknown)")
}

if skipIfModifiers && escapeModifiersHeld() {
    print("Shift or Option held — skipping.")
    exit(0)
}
if let delaySeconds, !dryRun { Thread.sleep(forTimeInterval: delaySeconds) }

/// Which displays a mutating command should act on.
///
/// `wanted` is the EDID about to be installed, if any; a service already
/// reporting the same panel is the best target, which is how SwitchResX picks.
/// `fallbackToAll` is for revert only — turning a virtual EDID off on a service
/// that never had one is a no-op, so the recovery path can afford to be broad.
/// Apply must never take that fallback: at login the EDID read can transiently
/// fail, and blindly applying to every service would latch this display's EDID
/// onto an unused port, where it persists until the next reboot.
/// `fatal: false` returns an empty array instead of exiting when the target
/// can't be identified. `watch` needs that: at wake the EDID read can race the
/// re-enumeration, and a resident reconciler must retry rather than die at the
/// exact moment it exists to act.
func selectTargets(
    _ all: [AVDisplay], wanted: EDID? = nil, fallbackToAll: Bool = false, fatal: Bool = true
) -> [AVDisplay] {
    if let indexOption {
        guard let match = all.first(where: { $0.index == indexOption }) else {
            if !fatal { return [] }
            fail("no display with index \(indexOption); run `avedid list`")
        }
        return [match]
    }
    if wantsAll { return all }

    if let wanted {
        let samePanel = all.filter {
            guard let edid = $0.edid else { return false }
            return edid.vendorID == wanted.vendorID && edid.productID == wanted.productID
        }
        if samePanel.count == 1 { return samePanel }
        // No connected display claims this EDID's identity. Refuse rather than
        // falling back: the usual cause is an EDID built for someone else's
        // panel, and installing it would feed foreign timings to this one.
        if samePanel.isEmpty {
            if !fatal { return [] }
            let seen = all.compactMap { $0.edid?.describedName }.joined(separator: ", ")
            fail(
                "this EDID identifies \(wanted.describedName), but no connected display "
                    + "reports that vendor/product.\n"
                    + "Connected: \(seen.isEmpty ? "(none readable)" : seen)\n"
                    + "Build an EDID for your own display, or pass --index N to override "
                    + "deliberately (see `avedid list`).")
        }
    }

    let matched = all.filter { $0.displayID != nil }
    if matched.count == 1 { return matched }
    if matched.count > 1 {
        if !fatal { return [] }
        fail(
            "\(matched.count) displays matched a CGDisplay; "
                + "pick one with --index or use --all (see `avedid list`)")
    }

    if fallbackToAll { return all }
    if !fatal { return [] }
    fail(
        "could not tell which display to act on — no service reported a usable EDID.\n"
            + "Re-run with --index N (see `avedid list`), or --all to mean every "
            + "external service.")
}

func confirm(_ prompt: String) {
    if assumeYes || dryRun { return }
    print(prompt, terminator: " [y/N] ")
    guard let reply = readLine()?.lowercased(), reply == "y" || reply == "yes" else {
        print("Aborted.")
        exit(1)
    }
}

// Answer --help before touching IOKit, so the binary is usable (and testable in
// CI) on a machine with no external display attached.
if ["-h", "--help", "help"].contains(command) {
    print(usage)
    exit(0)
}

let allDisplays = discoverDisplays()
if allDisplays.isEmpty {
    fail("no external DCPAVServiceProxy found. Is a display connected?")
}

switch command {
case "list":
    for display in allDisplays {
        print(display.label)
        if display.edid == nil {
            print("      (EDID could not be read from this service)")
        }
    }

case "dump":
    // This is what IOAVServiceCopyEDID sees, which is not always what ioreg
    // reports; the difference matters when watch decides whether to reinstall.
    for display in allDisplays {
        print(display.label)
        guard let edid = display.edid else {
            print("      (no EDID)")
            continue
        }
        for block in 0..<edid.blockCount {
            let slice = edid.bytes[(block * 128)..<((block + 1) * 128)]
            let hex = slice.map { String(format: "%02x", $0) }.joined()
            print("  block \(block): \(hex)")
        }
    }

case "modes":
    // A clock-probe rung that appears here passed macOS's enumeration filter;
    // whether it actually locks is a separate question, answered by set-hz.
    let targets = selectTargets(allDisplays, fallbackToAll: true)
    for target in targets {
        guard let displayID = target.displayID else {
            print("[\(target.index)] not matched to a CGDisplay, cannot list modes")
            continue
        }
        guard let (current, candidates) = modesAtCurrentResolution(displayID) else {
            print("[\(target.index)] could not read the current mode")
            continue
        }
        print(
            String(
                format: "[%d] CGDisplay %d — %dx%d points, %dx%d pixels",
                target.index, displayID, current.width, current.height,
                current.pixelWidth, current.pixelHeight))
        for mode in candidates.sorted(by: { $0.refreshRate < $1.refreshRate }) {
            let marker = mode.ioDisplayModeID == current.ioDisplayModeID ? "  <- current" : ""
            let vrr = modeIsVRR(displayID, mode.ioDisplayModeID)
                .map { $0 ? "  VRR" : "  fixed" } ?? ""
            print(String(format: "      %9.4f Hz  modeID=%-4d%@%@",
                mode.refreshRate, mode.ioDisplayModeID, vrr, marker))
        }
    }

case "set-hz":
    var hz: Double?
    if let raw = arguments.first, let parsed = Double(raw) { hz = parsed }
    if hz == nil && modeIDOption == nil {
        fail("set-hz needs a rate (`set-hz 86.5673`) or --mode-id N (see `avedid modes`)")
    }
    let targets = selectTargets(allDisplays, fallbackToAll: true)
    for target in targets {
        guard let displayID = target.displayID else { continue }
        if dryRun {
            print("would set [\(target.index)] to "
                + (modeIDOption.map { "modeID \($0)" } ?? "\(hz!) Hz"))
            continue
        }
        if let modeIDOption {
            print("[\(target.index)] \(selectModeID(displayID, modeID: modeIDOption))")
        } else {
            // Tight tolerance: probe rungs can be ~0.2 Hz apart.
            print("[\(target.index)] \(restoreRefreshRate(displayID, hz: hz!, tolerance: 0.05))")
        }
    }

case "apply":
    guard let path = arguments.first else { fail("apply needs a path to an EDID file") }
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    let edid = EDID(bytes: [UInt8](data))
    let problems = edid.validate()
    if !problems.isEmpty {
        fail(
            "\(path) does not look like a valid EDID:\n"
                + problems.map { "  - " + $0 }.joined(separator: "\n"))
    }

    let targets = selectTargets(allDisplays, wanted: edid)
    print("Installing \(edid.describedName) from \(path) on:")
    for target in targets { print("  " + target.label) }
    print()
    print("If the display goes black, reboot — a virtual EDID never survives one.")
    confirm("Continue?")

    for target in targets {
        if dryRun {
            print("would apply to [\(target.index)]")
            continue
        }
        let r = setVirtualEDID(target, data: data)
        print("[\(target.index)] IOAVServiceSetVirtualEDIDMode(enable) -> \(ioReturnName(r))")
    }
    if !dryRun && !noRedetect { redetectDisplays() }

case "revert":
    let targets = selectTargets(allDisplays, fallbackToAll: true)
    print("Restoring the real EDID on:")
    for target in targets { print("  " + target.label) }
    confirm("Continue?")

    for target in targets {
        if dryRun {
            print("would revert [\(target.index)]")
            continue
        }
        let r = setVirtualEDID(target, data: nil)
        print("[\(target.index)] IOAVServiceSetVirtualEDIDMode(disable) -> \(ioReturnName(r))")
    }
    if !dryRun && !noRedetect { redetectDisplays() }

case "watch":
    guard let path = arguments.first else { fail("watch needs a path to an EDID file") }
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    let wantedEDID = EDID(bytes: [UInt8](data))
    let problems = wantedEDID.validate()
    if !problems.isEmpty {
        fail(
            "\(path) does not look like a valid EDID:\n"
                + problems.map { "  - " + $0 }.joined(separator: "\n"))
    }

    func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
    func note(_ message: String) {
        print("\(stamp())  \(message)")
        fflush(stdout)
    }

    /// Reinstalling triggers a re-enumeration and, with --restore-hz, a mode
    /// change — both visible as a flash. If the installed-EDID check were ever
    /// to read something unequal in the steady state, an unthrottled reconcile
    /// would flash the display on every poll, so hold a floor between attempts.
    var lastApply: [Int: Date] = [:]
    let reapplyFloor: TimeInterval = 60

    /// Reinstall only if the panel is not already showing our EDID. That check
    /// is what keeps this from looping: applying triggers a reconfiguration,
    /// whose callback lands back here and finds nothing to do.
    func reconcile(_ reason: String) {
        let displays = discoverDisplays()
        guard !displays.isEmpty else {
            note("\(reason): no external display present, nothing to do")
            return
        }
        let targets = selectTargets(displays, wanted: wantedEDID, fatal: false)
        if targets.isEmpty {
            note("\(reason): can't identify the target display yet, will retry")
            return
        }
        for target in targets {
            if target.edid?.bytes == wantedEDID.bytes {
                if let restoreHz, let displayID = target.displayID {
                    let outcome = restoreRefreshRate(displayID, hz: restoreHz)
                    if !outcome.hasPrefix("already") {
                        note("\(reason): [\(target.index)] refresh rate — \(outcome)")
                    }
                }
                continue
            }
            if let previous = lastApply[target.index],
                Date().timeIntervalSince(previous) < reapplyFloor
            {
                continue
            }
            let seen = target.edid.map { "\($0.bytes.count) bytes" } ?? "unreadable"
            lastApply[target.index] = Date()
            let r = setVirtualEDID(target, data: data)
            note(
                "\(reason): [\(target.index)] EDID was \(seen), reinstalled "
                    + "\(wantedEDID.bytes.count) bytes -> \(ioReturnName(r))")
            guard r == kIOReturnSuccess else { continue }
            if !noRedetect { redetectDisplays() }
            guard let restoreHz else { continue }
            // Let the re-enumeration settle before asking for the new mode.
            Thread.sleep(forTimeInterval: 2.0)
            let displayID = discoverDisplays().first { $0.index == target.index }?.displayID
            if let displayID {
                note("\(reason): [\(target.index)] refresh rate — "
                    + restoreRefreshRate(displayID, hz: restoreHz))
            }
        }
    }

    note("watching for \(wantedEDID.describedName) from \(path)")
    if let restoreHz { note("will reselect \(restoreHz) Hz after each reinstall") }
    reconcile("startup")

    // Coalesce bursts — a wake produces several reconfiguration callbacks.
    var pending: DispatchWorkItem?
    func schedule(_ reason: String, after seconds: Double = 2.0) {
        pending?.cancel()
        let item = DispatchWorkItem { reconcile(reason) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    reconfigureHook = { schedule("display reconfigured") }
    CGDisplayRegisterReconfigurationCallback(
        { _, _, _ in reconfigureHook?() }, nil)

    let workspace = NSWorkspace.shared.notificationCenter
    for name: NSNotification.Name in [
        NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
    ] {
        workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
            schedule("woke (\(name.rawValue))", after: 3.0)
        }
    }

    // Events should catch everything; this is the backstop if one is missed.
    Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
        reconcile("poll")
    }

    RunLoop.main.run()

default:
    fail("unknown command \(command)\n\n" + usage)
}
