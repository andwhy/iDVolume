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
//
// A copy of the volume indicator of macOS 26 and later: a Liquid Glass panel
// that drops out of the menu bar under its icon there, with the device name
// over a bar that has a speaker at each end and a tick every 6 dB, 16 steps
// like the system's. Muted, the bar is simply empty. The device's own name is
// the only text, so there is nothing to translate.

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

// The menu bar item the indicator hangs from, found through Accessibility,
// which the key tap needs anyway: a Sound item if the menu bar shows one,
// else Control Center's, which on macOS 27 turns into a speaker while the
// volume changes. Since macOS 27 they belong to MenuBarAgent.
func volumeMenuExtraFrame() -> NSRect? {
    let ids = ["com.apple.menuextra.sound", "com.apple.menuextra.controlcenter"]
    var found: [String: CGRect] = [:]
    func visit(_ element: AXUIElement, depth: Int) {
        if let id: String = axValue(element, kAXIdentifierAttribute), ids.contains(id), found[id] == nil,
           let value: AXValue = axValue(element, "AXFrame") {
            var frame = CGRect.zero
            if AXValueGetValue(value, .cgRect, &frame) { found[id] = frame }
        }
        guard depth < 2, let children: [AXUIElement] = axValue(element, kAXChildrenAttribute) else { return }
        children.forEach { visit($0, depth: depth + 1) }
    }
    for bundle in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier,
              let bar: AXUIElement = axValue(AXUIElementCreateApplication(pid), kAXExtrasMenuBarAttribute) else { continue }
        visit(bar, depth: 0)
    }
    // Accessibility counts from the top left of the main display, AppKit from its bottom left
    guard let frame = ids.lazy.compactMap({ found[$0] }).first, let main = NSScreen.screens.first else { return nil }
    return NSRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
}

final class LevelBar: NSView {
    static let steps = 16
    private let inset: CGFloat = 5  // from the ends of the bar to the ends of the scale
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let line = CGRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4)
        for (part, alpha) in [(track, 0.4), (fill, 1.0)] {
            part.frame = line
            part.cornerRadius = line.height / 2
            part.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            layer?.addSublayer(part)
        }
        for step in 0...Self.steps {
            let tick = CALayer()
            let x = inset + (line.width - 2 * inset) * CGFloat(step) / CGFloat(Self.steps)
            tick.frame = CGRect(x: x - 0.75, y: 0, width: 1.5, height: 2.5)
            tick.cornerRadius = 0.75
            tick.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer?.addSublayer(tick)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Like the system's, the fill ends right over the tick of its level.
    func set(_ fraction: Double, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        fill.frame.size.width = fraction > 0 ? inset + (track.frame.width - 2 * inset) * fraction : 0
        CATransaction.commit()
    }
}

final class VolumeHUD {
    private let size = NSSize(width: 292, height: 62)
    private let gap: CGFloat = 11   // to the menu bar and the screen edge
    private let room: CGFloat = 24  // around the panel, for the fall and the spring
    private let panel: NSPanel
    private let mover = NSView()
    private let title = NSTextField(labelWithString: "")
    private let bar = LevelBar(frame: NSRect(x: 31, y: 14, width: 222, height: 10))
    private var shown = false
    private var generation = 0

    init() {
        // a hung menu bar must not hold up the key tap
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        let frame = NSRect(origin: .zero, size: size).insetBy(dx: -room, dy: -room)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // dark like the system's in either mode, so the white reads on any background
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        title.frame = NSRect(x: 15, y: 36, width: size.width - 30, height: 16)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        let quiet = Self.speaker("speaker.fill"), loud = Self.speaker("speaker.wave.3.fill")
        quiet.setFrameOrigin(NSPoint(x: 14, y: 22 - quiet.frame.height / 2))
        loud.setFrameOrigin(NSPoint(x: size.width - 14 - loud.frame.width, y: 22 - loud.frame.height / 2))
        [title, quiet, bar, loud].forEach(content.addSubview)

        let card = Self.backdrop(for: content)
        card.frame = content.frame
        mover.frame = NSRect(origin: NSPoint(x: room, y: room), size: size)
        mover.wantsLayer = true
        mover.addSubview(card)
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.addSubview(mover)
        panel.contentView = root
    }

    // Clear Liquid Glass like the system's; the blurred HUD of old where the
    // system or the SDK (before Xcode 26) has no glass.
    private static func backdrop(for content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if let glass = lightGlass(for: content) { return glass }
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 22
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: 22)
        effect.addSubview(content)
        return effect
    }

    #if compiler(>=6.2)
    // The system's own panel, drawn by MenuBarAgent, blurs what is behind it
    // by about 3 pt; the public glass blurs by about 10 and hides it. Private
    // Core Animation pieces come as close as it gets: a backdrop layer with a
    // light gaussian blur under a darkening, and on top glass variant 13,
    // which only bends the light at the edge. Every piece is looked up first;
    // if one is missing, nil, and the public glass is used.
    @available(macOS 26, *)
    private static func lightGlass(for content: NSView) -> NSView? {
        let filterWithType = NSSelectorFromString("filterWithType:"), inputKeys = NSSelectorFromString("inputKeys")
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              backdropType.instancesRespond(to: NSSelectorFromString("setWindowServerAware:")),
              let filterType = NSClassFromString("CAFilter") as AnyObject?, filterType.responds(to: filterWithType),
              let blur = filterType.perform(filterWithType, with: "gaussianBlur" as NSString)?.takeUnretainedValue() as? NSObject,
              blur.responds(to: inputKeys),
              (blur.perform(inputKeys)?.takeUnretainedValue() as? [String])?.contains("inputRadius") == true,
              NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:"))
        else { return nil }
        blur.setValue(3, forKey: "inputRadius")
        let backdrop = backdropType.init()
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.filters = [blur]
        let darkening = CALayer()
        darkening.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor

        let view = NSView(frame: content.frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        for layer in [backdrop, darkening] {
            layer.frame = view.bounds
            view.layer?.addSublayer(layer)
        }
        let edge = NSGlassEffectView(frame: view.bounds)
        edge.cornerRadius = 22
        edge.setValue(13, forKey: "_variant")
        [edge, content].forEach(view.addSubview)
        return view
    }
    #endif

    private static func speaker(_ symbol: String) -> NSImageView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = .white
        view.frame.size = image.size
        return view
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

    // Where the system's hangs: centred under its menu bar item, or in the
    // top right corner when the menu bar doesn't show one.
    private func placement() -> NSRect? {
        let origin: NSPoint
        if let item = volumeMenuExtraFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) }) {
            let x = min(max(item.midX - size.width / 2, screen.frame.minX + gap), screen.frame.maxX - gap - size.width)
            origin = NSPoint(x: x, y: screen.visibleFrame.maxY - gap - size.height)
        } else if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origin = NSPoint(x: screen.maxX - gap - size.width, y: screen.maxY - gap - size.height)
        } else {
            return nil
        }
        return NSRect(origin: origin, size: size).insetBy(dx: -room, dy: -room)
    }

    // Up in the menu bar and a little smaller, scaled about the top edge, so
    // that the panel seems to drop out of it.
    private var tucked: CATransform3D {
        let anchor = mover.layer?.anchorPoint ?? .zero
        let top = CGPoint(x: (0.5 - anchor.x) * size.width, y: (1 - anchor.y) * size.height)
        let raised = CATransform3DMakeTranslation(top.x, top.y + 20, 0)
        return CATransform3DTranslate(CATransform3DScale(raised, 0.8, 0.8, 1), -top.x, -top.y, 0)
    }

    private func appear() {
        guard let layer = mover.layer else { return }
        // from wherever a leaving panel has got to
        let current = panel.isVisible ? layer.presentation() : nil
        let fall = CASpringAnimation(keyPath: "transform")
        fall.fromValue = NSValue(caTransform3D: current?.transform ?? tucked)
        fall.stiffness = 280
        fall.damping = 22
        fall.duration = fall.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current?.opacity ?? 0
        fade.duration = 0.15
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(fall, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        shown = true
        panel.orderFrontRegardless()
    }

    private func disappear(_ last: Int) {
        guard let layer = mover.layer else { return }
        shown = false
        let current = layer.presentation()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == last else { return }
            self.panel.orderOut(nil)
        }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: current?.transform ?? CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current?.opacity ?? 1
        for animation in [rise, fade] {
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        layer.transform = tucked
        layer.opacity = 0
        layer.add(rise, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    func show(_ state: MonitorState, device: String) {
        title.stringValue = device
        bar.set(state.fraction, animated: shown)
        if !shown {
            if !panel.isVisible {
                guard let frame = placement() else { return }
                panel.setFrame(frame, display: false)
            }
            appear()
        }
        generation += 1
        let last = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == last else { return }
            self.disappear(last)
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
