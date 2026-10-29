import AppKit
import CoreAudio
import IOKit
import IOUSBHost

// MARK: - Audient iD control
//
// The iD's own control protocol, as reverse engineered by the Linux projects
// MixiD and BiD (github.com/baakhoff/BiD, docs/PROTOCOL.md): UAC2-style class
// requests aimed at the spare DFU interface, which no macOS driver claims, so
// audio keeps playing. The monitor level is entity 0x36 selector 0x12 - the
// node the front encoder itself moves, so the knob and the keys stay in step.
// Levels are int16 in 1/256 dB; 0x8000 is silence.

enum Audient {
    static let vendorID = 0x2708
    static let controlInterface: UInt16 = 4
    static let monitorEntity: UInt16 = 0x36
    static let volumeSelector: UInt16 = 0x12
    static let muteSelector: UInt16 = 0x04
    static let silent = Int16.min

    static let minDB = -96.0
    static let maxDB = 0.0
    static let stepDB = 2.0
    static let fineStepDB = 0.5
    // presses closer than quickPress seconds apart add stepGrowthDB each;
    // a held key steps at most once per holdInterval, as if pressed that fast
    static let quickPress = 0.35
    static let holdInterval = 0.15
    static let stepGrowthDB = 1.0
    static let maxStepDB = 5.0
}

struct MonitorState {
    var raw: Int16
    var muted: Bool

    var db: Double? { raw == Audient.silent ? nil : Double(raw) / 256 }
    var fraction: Double {
        guard let db, !muted else { return 0 }
        return min(1, max(0, (db - Audient.minDB) / (Audient.maxDB - Audient.minDB)))
    }
}

final class MonitorControl {
    // The device reports a write back only 5-20 ms later, so a quick second
    // press would read the old value: a double mute tap muted twice.
    private var lastWrite: (state: MonitorState, time: Date)?

    private func findService() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        let parents = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, nil, parents) as? Int
            let number = IORegistryEntryCreateCFProperty(service, "bInterfaceNumber" as CFString, nil, 0)?.takeRetainedValue() as? Int
            if vendor == Audient.vendorID && number == Int(Audient.controlInterface) { return service }
            IOObjectRelease(service)
        }
        return 0
    }

    // Holds the interface only for one change (well under a millisecond), so
    // replugging, sleep and the official iD app never find it taken.
    private func withInterface<T>(_ body: (IOUSBHostInterface) throws -> T) -> T? {
        let service = findService()
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        do {
            let iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { iface.destroy() }
            return try body(iface)
        } catch {
            NSLog("iDVolume: USB error: \(error.localizedDescription)")
            return nil
        }
    }

    private func transfer(_ iface: IOUSBHostInterface, read: Bool, selector: UInt16, bytes: [UInt8]) throws -> [UInt8] {
        let request = IOUSBDeviceRequest(bmRequestType: read ? 0xa1 : 0x21, bRequest: 0x01, wValue: selector << 8,
                                         wIndex: Audient.monitorEntity << 8 | Audient.controlInterface,
                                         wLength: UInt16(bytes.count))
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        try iface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 0.5)
        return Array(Data(referencing: data).prefix(transferred))
    }

    private func readState(_ iface: IOUSBHostInterface) throws -> MonitorState {
        if let lastWrite, Date().timeIntervalSince(lastWrite.time) < 0.3 { return lastWrite.state }
        let level = try transfer(iface, read: true, selector: Audient.volumeSelector, bytes: [0, 0])
        let mute = try transfer(iface, read: true, selector: Audient.muteSelector, bytes: [0])
        guard level.count == 2, mute.count == 1 else { throw CocoaError(.coderReadCorrupt) }
        return MonitorState(raw: Int16(bitPattern: UInt16(level[0]) | UInt16(level[1]) << 8), muted: mute[0] != 0)
    }

    // Reads the level first every time, so a turn of the knob in between is
    // simply where the next key press starts from.
    func adjust(by step: Double) -> MonitorState? {
        withInterface { iface in
            var state = try readState(iface)
            let target: Double
            if let db = state.db {
                target = db + step
            } else {
                target = step > 0 ? Audient.minDB : Audient.minDB - 1
            }
            let raw = target < Audient.minDB ? Audient.silent : Int16((min(target, Audient.maxDB) * 256).rounded())
            if raw != state.raw {
                let bits = UInt16(bitPattern: raw)
                _ = try transfer(iface, read: false, selector: Audient.volumeSelector, bytes: [UInt8(bits & 0xff), UInt8(bits >> 8)])
                state.raw = raw
            }
            // like the system volume: any volume key lifts mute
            if state.muted {
                _ = try transfer(iface, read: false, selector: Audient.muteSelector, bytes: [0])
                state.muted = false
            }
            lastWrite = (state, Date())
            return state
        }
    }

    func toggleMute() -> MonitorState? {
        withInterface { iface in
            var state = try readState(iface)
            state.muted.toggle()
            _ = try transfer(iface, read: false, selector: Audient.muteSelector, bytes: [state.muted ? 1 : 0])
            lastWrite = (state, Date())
            return state
        }
    }
}

// MARK: - Default output

func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

// The name of the default output when it is an Audient, nil otherwise; the
// keys are left to macOS for every other device.
func audientDefaultOutput() -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          stringProperty(device, kAudioObjectPropertyManufacturer) == "Audient" else { return nil }
    return stringProperty(device, kAudioObjectPropertyName) ?? "Audient"
}

// MARK: - HUD

final class LevelBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * fraction)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

final class VolumeHUD {
    private let size = NSSize(width: 300, height: 64)
    private let panel: NSPanel
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 18)
        panel.contentView = effect

        icon.frame = NSRect(x: 16, y: 20, width: 24, height: 24)
        icon.contentTintColor = .labelColor
        title.frame = NSRect(x: 52, y: 34, width: 232, height: 16)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        bar.frame = NSRect(x: 52, y: 19, width: 172, height: 6)
        value.frame = NSRect(x: 228, y: 14, width: 58, height: 16)
        value.alignment = .right
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = .labelColor
        [icon, title, bar, value].forEach(effect.addSubview)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(_ state: MonitorState, device: String) {
        let silent = state.muted || state.db == nil
        let symbol: String
        switch state.fraction {
        case _ where silent: symbol = "speaker.slash.fill"
        case ..<0.34: symbol = "speaker.wave.1.fill"
        case ..<0.67: symbol = "speaker.wave.2.fill"
        default: symbol = "speaker.wave.3.fill"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        title.stringValue = device
        bar.fraction = state.fraction
        if state.muted {
            value.stringValue = "выкл"
        } else if let db = state.db {
            value.stringValue = String(format: db == db.rounded() ? "%.0f dB" : "%.1f dB", db)
                .replacingOccurrences(of: "-", with: "−")
        } else {
            value.stringValue = "−∞ dB"
        }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 14))
        }
        generation += 1
        let shown = generation
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == shown else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.generation == shown { self.panel.orderOut(nil) }
            })
        }
    }
}

// MARK: - Volume keys

// Media keys arrive as NX_SYSDEFINED events, subtype 8, with the key in data1.
let systemDefinedEvent: UInt32 = 14
let soundUpKey = 0, soundDownKey = 1, muteKey = 7

final class VolumeKeys {
    private let control = MonitorControl()
    private let hud = VolumeHUD()
    private var lastStep: (key: Int, time: Date, size: Double)?

    // Quick presses in one direction grow the step, the way the front knob
    // speeds up when turned fast, and holding the key counts as pressing it
    // quickly. The system repeats a held key far more often than anyone can
    // press, so repeats closer than holdInterval are dropped (nil); that also
    // spares the iD's control interface a flood of requests.
    private func step(for key: Int, fine: Bool, isRepeat: Bool) -> Double? {
        let now = Date()
        var size = fine ? Audient.fineStepDB : Audient.stepDB
        if let lastStep, lastStep.key == key {
            let since = now.timeIntervalSince(lastStep.time)
            if isRepeat && since < Audient.holdInterval { return nil }
            if !fine && (isRepeat || since < Audient.quickPress) {
                size = min(lastStep.size + Audient.stepGrowthDB, Audient.maxStepDB)
            }
        }
        lastStep = (key, now, size)
        return size
    }

    // true when the event is ours and must not reach macOS
    func handle(_ event: CGEvent) -> Bool {
        guard event.type.rawValue == systemDefinedEvent,
              let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
        let key = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
        let isRepeat = nsEvent.data1 & 0x1 != 0
        guard key == soundUpKey || key == soundDownKey || key == muteKey else { return false }

        let flags = event.flags
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        // Option alone keeps its system meaning: it opens Sound settings
        if flags.contains(.maskAlternate) && !fine { return false }
        guard let device = audientDefaultOutput() else { return false }
        guard isDown else { return true }

        let state: MonitorState?
        switch key {
        case soundUpKey, soundDownKey:
            // a held key between two steps: nothing to change, still ours
            guard let step = step(for: key, fine: fine, isRepeat: isRepeat) else { return true }
            state = control.adjust(by: key == soundUpKey ? step : -step)
        default: state = control.toggleMute()
        }
        // could not reach the device: let macOS answer as it always did
        guard let state else { return false }
        hud.show(state, device: device)
        return true
    }
}

let volumeKeys = VolumeKeys()
var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return volumeKeys.handle(event) ? nil : Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1) << systemDefinedEvent,
                                      callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// Swallowing keys needs Accessibility. Ask once, then wait for the switch to
// be flipped in System Settings instead of making the user relaunch.
func startWhenTrusted() {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(prompt), installTap() {
        NSLog("iDVolume: listening for volume keys")
        return
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        guard AXIsProcessTrusted(), installTap() else { return }
        timer.invalidate()
        NSLog("iDVolume: listening for volume keys")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
startWhenTrusted()
app.run()
