// WakeWave: a menu bar app that keeps an AUX or Bluetooth speaker awake by playing an
// inaudible 20 Hz tone (-30 dBFS) straight to an output device through a Core Audio IOProc.
// Automatic mode follows macOS's default output device; a specific device can be picked instead.
// No polling: it reacts only to Core Audio property listeners, the system wake notification, and a
// single one-shot timer at the end of a chosen duration.
// CLI flags for testing: --selftest (tone math, no hardware), --list (output devices), --probe N.
import Cocoa
import CoreAudio

let toneFrequency = 20.0
let toneAmplitude: Float = 0.031622777            // -30 dBFS = 10^(-30/20); --selftest checks it
let wantedBufferFrames: UInt32 = 4096             // bigger IO buffer = fewer wakeups (~12/s at 48 kHz)
let durationChoices: [(minutes: Int?, title: String)] = [
    (nil, "Indefinitely"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"),
    (120, "2 hours"), (240, "4 hours"), (480, "8 hours"),
]
let prefDeviceUID = "deviceUID", prefDeviceName = "deviceName"
let keepAliveGreen = NSColor(srgbRed: 61 / 255.0, green: 225 / 255.0, blue: 85 / 255.0, alpha: 1)  // #3DE155
let systemObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Tone

// One cycle of the sine, computed once per device start; rendering is then a table copy with no trig.
struct ToneGenerator {
    let table: [Float]
    var index = 0

    init(sampleRate: Double) {
        let n = max(Int((sampleRate / toneFrequency).rounded()), 4)   // 2400 samples at 48 kHz
        table = (0..<n).map { toneAmplitude * Float(sin(2 * Double.pi * Double($0) / Double(n))) }
    }

    // Interleaved Float32, the same sample on every channel; the position carries across calls.
    mutating func render(_ out: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        var i = index
        table.withUnsafeBufferPointer { t in
            var o = out
            for _ in 0..<frames {
                let s = t[i]
                for c in 0..<channels { o[c] = s }
                o += channels
                i += 1
                if i == t.count { i = 0 }
            }
        }
        index = i
    }
}

// Owned by the IO thread while the device runs; read by the main thread only after AudioDeviceStop.
final class Renderer {
    var generator: ToneGenerator
    var callbacks = 0, frames = 0, lastBufferFrames = 0
    init(sampleRate: Double) { generator = ToneGenerator(sampleRate: sampleRate) }

    func render(_ abl: UnsafeMutableAudioBufferListPointer) {
        guard abl.count > 0, let d0 = abl[0].mData else { return }
        let ch0 = max(Int(abl[0].mNumberChannels), 1)
        let n = Int(abl[0].mDataByteSize) / (4 * ch0)
        let p0 = d0.assumingMemoryBound(to: Float.self)
        generator.render(p0, frames: n, channels: ch0)
        for i in 1..<abl.count {            // other streams (rare) get the same samples
            guard let d = abl[i].mData else { continue }
            let ch = max(Int(abl[i].mNumberChannels), 1)
            let p = d.assumingMemoryBound(to: Float.self)
            for f in 0..<min(n, Int(abl[i].mDataByteSize) / (4 * ch)) {
                for c in 0..<ch { p[f * ch + c] = p0[f * ch0] }
            }
        }
        callbacks += 1; frames += n; lastBufferFrames = n
    }
}

// MARK: - Core Audio helpers

struct OutputDevice { let id: AudioDeviceID; let name: String; let uid: String }

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func outputStreams(_ id: AudioDeviceID) -> [AudioStreamID] {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr else { return [] }
    return streams
}

func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard status == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return 48000 }
    return rate
}

// Safety: only ever write Float32 samples into a stream whose format really is 32-bit float PCM.
func outputIsFloat32(_ id: AudioDeviceID) -> Bool {
    let streams = outputStreams(id)
    guard !streams.isEmpty else { return false }
    for s in streams {
        var addr = address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(s, &addr, 0, nil, &size, &asbd) == noErr,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return false }
    }
    return true
}

// The IO buffer size is per process, so this does not change other apps' latency.
func setBufferFrames(_ id: AudioDeviceID, _ wanted: UInt32) {
    var frames = wanted
    var rangeAddr = address(kAudioDevicePropertyBufferFrameSizeRange)
    var range = AudioValueRange()
    var rsize = UInt32(MemoryLayout<AudioValueRange>.size)
    if AudioObjectGetPropertyData(id, &rangeAddr, 0, nil, &rsize, &range) == noErr, range.mMaximum > 0 {
        frames = min(wanted, UInt32(range.mMaximum))
    }
    var addr = address(kAudioDevicePropertyBufferFrameSize)
    _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
}

// The device macOS is currently sending audio to (System Settings > Sound > Output).
func defaultOutputDevice() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

// One Core Audio call instead of enumerating every device; nil when that device is not connected.
func device(forUID uid: String) -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &cfUID) {
        AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == noErr && id != kAudioObjectUnknown ? id : nil
}

func outputDevices() -> [OutputDevice] {
    allDevices().filter { !outputStreams($0).isEmpty }.compactMap { id in
        guard let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return OutputDevice(id: id, name: name, uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "")
    }
}

// MARK: - Engine (main thread only)

final class Engine {
    private(set) var enabled = false
    private(set) var until: Date?                 // end of the chosen duration; nil = indefinitely
    private(set) var activeMinutes: Int?          // the duration choice in effect while enabled
    private(set) var selectedUID: String?         // nil = Automatic (follow the default output device)
    private(set) var selectedName: String?
    private(set) var current: AudioDeviceID?
    private(set) var currentName: String?
    private(set) var renderer: Renderer?
    private(set) var lastError: String?
    var onChange: (() -> Void)?
    private var procID: AudioDeviceIOProcID?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var expiry: Timer?                    // one-shot, fires once at `until`

    init(selectedUID: String? = nil, selectedName: String? = nil) {
        self.selectedUID = selectedUID
        self.selectedName = selectedName
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(sel)
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main) { [weak self] _, _ in self?.reevaluate() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    func turnOn(minutes: Int?) {
        resetToOff()
        enabled = true; activeMinutes = minutes
        if let m = minutes {
            let seconds = TimeInterval(m * 60)
            until = Date(timeIntervalSinceNow: seconds)
            let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.turnOff() }
            RunLoop.main.add(t, forMode: .common)     // .common so it also fires while a menu is open
            expiry = t
        }
        reevaluate()
    }

    func turnOff() { resetToOff(); reevaluate() }

    private func resetToOff() {
        expiry?.invalidate(); expiry = nil
        enabled = false; activeMinutes = nil; until = nil
    }

    func select(uid: String?, name: String?) {
        selectedUID = uid; selectedName = name
        UserDefaults.standard.set(uid, forKey: prefDeviceUID)    // nil removes the key = Automatic
        UserDefaults.standard.set(name, forKey: prefDeviceName)
        restart()
    }

    func reevaluate() {
        defer { onChange?() }
        if enabled, let u = until, Date() >= u { resetToOff() }  // duration ran out while the Mac slept
        guard enabled else { stop(); lastError = nil; return }
        let target: AudioDeviceID?
        if let uid = selectedUID { target = device(forUID: uid) } else { target = defaultOutputDevice() }
        if let t = target, t == current { return }
        stop()
        lastError = nil
        if let t = target { start(t) }
    }

    func restart() { stop(); reevaluate() }

    private func start(_ id: AudioDeviceID) {
        let name = stringProperty(id, kAudioObjectPropertyName) ?? "Output device"
        guard outputIsFloat32(id) else { lastError = "\(name): not a 32-bit float output, skipped"; return }
        setBufferFrames(id, wantedBufferFrames)
        let r = Renderer(sampleRate: nominalSampleRate(id))
        var pid: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&pid, id, nil, { _, _, _, out, _ in
            r.render(UnsafeMutableAudioBufferListPointer(out))
        }) == noErr, let p = pid else { lastError = "\(name): could not create the audio callback"; return }
        guard AudioDeviceStart(id, p) == noErr else {
            AudioDeviceDestroyIOProcID(id, p)
            lastError = "\(name): could not start audio"; return
        }
        current = id; currentName = name; renderer = r; procID = p
        for sel in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            var addr = address(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
            if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                deviceListeners.append((addr, block))
            }
        }
    }

    func stop() {
        guard let device = current else { return }
        for (a, block) in deviceListeners {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
        }
        deviceListeners.removeAll()
        if let p = procID {
            AudioDeviceStop(device, p)
            AudioDeviceDestroyIOProcID(device, p)
        }
        current = nil; currentName = nil; procID = nil
    }
}

// MARK: - Menu bar UI

// Hand-drawn switch: a real NSSwitch inside a menu always draws its inactive gray style (a menu's
// window is never key), so it can't turn blue. This one is blue when on and plain gray when off.
final class MenuSwitch: NSView {
    var isOn = false { didSet { if isOn != oldValue { update(animated: true) } } }
    var onToggle: ((Bool) -> Void)?
    private let track = CALayer(), knob = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()                         // layer-hosting view: it owns its sublayers
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        let h = bounds.height - 4
        knob.bounds = CGRect(x: 0, y: 0, width: h * 1.5, height: h)
        knob.cornerRadius = h / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 0.25; knob.shadowRadius = 1; knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track); layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox); setAccessibilitySubrole(.switch)
        setAccessibilityLabel("WakeWave")
        update(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = (isOn ? NSColor.systemBlue : NSColor.labelColor.withAlphaComponent(0.2)).cgColor
        }
        let half = knob.bounds.width / 2
        knob.position = CGPoint(x: isOn ? bounds.width - 2 - half : 2 + half, y: bounds.midY)
        CATransaction.commit()
        setAccessibilityValue(isOn ? 1 : 0)
    }

    override func viewDidChangeEffectiveAppearance() { update(animated: false) }
    override func mouseDown(with event: NSEvent) {}   // act on release, like a menu item
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
    private func toggle() { isOn.toggle(); onToggle?(isOn) }
}

// An image view that lets clicks through to the status bar button underneath it.
final class PassThroughImageView: NSImageView {
    var onAppearanceChange: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { onAppearanceChange?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine(selectedUID: UserDefaults.standard.string(forKey: prefDeviceUID),
                        selectedName: UserDefaults.standard.string(forKey: prefDeviceName))
    var item: NSStatusItem!
    let menu = NSMenu()
    var menuIsOpen = false                         // rebuild items only while someone is looking
    let headerIcon = NSImageView(frame: NSRect(x: 14, y: 8, width: 18, height: 18))
    let barIcon = PassThroughImageView()
    let headerSwitch = MenuSwitch(frame: NSRect(x: 280 - 14 - 48, y: 6, width: 48, height: 22))
    lazy var header = makeHeader()                 // kept across rebuilds so the switch can animate

    func applicationDidFinishLaunching(_ note: Notification) {
        setUpStatusItem()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        engine.onChange = { [weak self] in self?.refresh() }
        engine.turnOn(minutes: nil)                    // opening the app means "keep it awake"
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true; rebuildMenu() }   // fresh device list
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    // The menu bar icon is an image view tinting the solid template symbol, which renders sharper
    // than the button's own image. 14 pt is a whole size, so edges stay on pixels on 1x displays, and
    // the frame is set by hand to whole pixels: centered with floor(), never a half-pixel offset.
    func setUpStatusItem() {
        let symbol = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))!
        item = NSStatusBar.system.statusItem(withLength: symbol.size.width + 4)   // 2 pt each side
        guard let button = item.button else { return }
        button.toolTip = "WakeWave"
        button.setAccessibilityLabel("WakeWave")
        barIcon.image = symbol
        barIcon.onAppearanceChange = { [weak self] in self?.refresh() }
        button.addSubview(barIcon)
        button.postsFrameChangedNotifications = true    // re-center if the menu bar height changes
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                               queue: .main) { [weak self] _ in self?.centerBarIcon() }
        centerBarIcon()
    }

    func centerBarIcon() {
        guard let button = item.button, let s = barIcon.image?.size else { return }
        barIcon.frame = NSRect(x: floor((button.bounds.width - s.width) / 2),
                               y: floor((button.bounds.height - s.height) / 2), width: s.width, height: s.height)
    }

    // Green while on; solid white while off (solid black on a light menu bar). Solid colors, not
    // labelColor, which in the menu bar is 90% white blended with the wallpaper.
    func refresh() {
        let dark = [.darkAqua, .vibrantDark].contains(
            barIcon.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]))
        barIcon.contentTintColor = engine.enabled ? keepAliveGreen : (dark ? .white : .black)
        if menuIsOpen { rebuildMenu() }
    }

    func rebuildMenu() {
        if menu.items.first !== header { menu.removeAllItems(); menu.addItem(header) }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        headerSwitch.isOn = engine.enabled

        if let e = engine.lastError {
            let err = NSMenuItem(title: e, action: nil, keyEquivalent: "")
            err.isEnabled = false
            menu.addItem(err)
        }
        menu.addItem(.separator())

        let durations = NSMenu()
        durations.autoenablesItems = false
        for (i, choice) in durationChoices.enumerated() {
            let m = NSMenuItem(title: choice.title, action: #selector(chooseDuration(_:)), keyEquivalent: "")
            m.target = self; m.tag = i
            m.state = engine.enabled && engine.activeMinutes == choice.minutes ? .on : .off
            durations.addItem(m)
        }
        let durationItem = NSMenuItem(title: "Turn On for", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(durationItem)

        let speakers = NSMenu()
        speakers.autoenablesItems = false
        let auto = NSMenuItem(title: "Automatic", action: #selector(chooseSpeaker(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = engine.selectedUID == nil ? .on : .off
        speakers.addItem(auto)
        speakers.addItem(.separator())
        let outs = outputDevices()
        for d in outs {
            let m = NSMenuItem(title: d.name, action: #selector(chooseSpeaker(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = [d.uid, d.name]
            m.state = engine.selectedUID == d.uid ? .on : .off
            speakers.addItem(m)
        }
        if let uid = engine.selectedUID, !outs.contains(where: { $0.uid == uid }) {
            let m = NSMenuItem(title: "\(engine.selectedName ?? uid) (not connected)", action: nil, keyEquivalent: "")
            m.state = .on; m.isEnabled = false
            speakers.addItem(m)
        }
        let speakerItem = NSMenuItem(title: "Speaker", action: nil, keyEquivalent: "")
        speakerItem.submenu = speakers
        menu.addItem(speakerItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func makeHeader() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        view.autoresizingMask = [.width]           // the menu stretches the row to its own width...
        headerSwitch.autoresizingMask = [.minXMargin]   // ...and the switch stays pinned to the right edge
        headerIcon.image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)
        headerIcon.contentTintColor = .labelColor  // solid and white in the dark menu, whatever the state
        let label = NSTextField(labelWithString: "WakeWave")
        label.font = .boldSystemFont(ofSize: 13)
        label.frame = NSRect(x: 38, y: 8, width: 170, height: 18)
        headerSwitch.onToggle = { [weak self] on in   // async: let the click finish before the menu changes
            DispatchQueue.main.async {
                guard let engine = self?.engine else { return }
                if on { engine.turnOn(minutes: nil) } else { engine.turnOff() }
            }
        }
        [headerIcon, label, headerSwitch].forEach { view.addSubview($0) }
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc func chooseDuration(_ sender: NSMenuItem) { engine.turnOn(minutes: durationChoices[sender.tag].minutes) }

    @objc func chooseSpeaker(_ sender: NSMenuItem) {
        let pair = sender.representedObject as? [String]
        engine.select(uid: pair?[0], name: pair?[1])
    }

    @objc func quitApp() { engine.turnOff(); NSApp.terminate(nil) }
}

// MARK: - CLI test modes

func selfTest() -> Bool {
    var reasons: [String] = []
    let exact = Float(pow(10.0, -30.0 / 20.0))
    if abs(toneAmplitude - exact) > 1e-7 { reasons.append("toneAmplitude \(toneAmplitude) != \(exact)") }
    var report = ""
    for rate in [48000.0, 44100.0] {
        let channels = 2, total = Int(rate)            // one second
        var chunked = [Float](repeating: 0, count: total * channels)
        var single = chunked
        var g1 = ToneGenerator(sampleRate: rate), g2 = ToneGenerator(sampleRate: rate)
        chunked.withUnsafeMutableBufferPointer { buf in
            var done = 0
            while done < total {                       // odd chunk size exercises the table wrap
                let n = min(509, total - done)
                g1.render(buf.baseAddress! + done * channels, frames: n, channels: channels)
                done += n
            }
        }
        single.withUnsafeMutableBufferPointer { g2.render($0.baseAddress!, frames: total, channels: channels) }
        let left = stride(from: 0, to: chunked.count, by: 2).map { chunked[$0] }
        let channelsEqual = stride(from: 0, to: chunked.count, by: 2).allSatisfy { chunked[$0] == chunked[$0 + 1] }
        let peak = left.map { abs($0) }.max() ?? 0
        let crossings = zip(left, left.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        if chunked != single { reasons.append("\(Int(rate)): chunked != single") }
        if !channelsEqual { reasons.append("\(Int(rate)): channels differ") }
        if abs(peak - toneAmplitude) > toneAmplitude * 0.01 { reasons.append("\(Int(rate)): peak \(peak)") }
        if abs(crossings - 40) > 1 { reasons.append("\(Int(rate)): crossings \(crossings)") }
        report += " \(Int(rate)):table=\(g1.table.count),peak=\(peak),crossings=\(crossings)"
    }
    print(reasons.isEmpty ? "SELFTEST OK" + report : "SELFTEST FAIL " + reasons.joined(separator: "; "))
    return reasons.isEmpty
}

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "--selftest":
        exit(selfTest() ? 0 : 1)
    case "--list":                          // "*" marks the default output, what Automatic follows
        let def = defaultOutputDevice()
        for d in outputDevices() { print("\(d.id == def ? "*" : " ") \(d.name)\t\(d.uid)") }
        exit(0)
    case "--probe":                         // Automatic target, saved speaker choice ignored
        let seconds = args.count > 2 ? Double(args[2]) ?? 2 : 2
        let engine = Engine()
        engine.turnOn(minutes: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        let name = engine.currentName ?? "none"
        let device = engine.current
        let r = engine.renderer
        engine.stop()                       // after this the IO thread no longer touches r
        let rate = device.map(nominalSampleRate) ?? 0
        print("device=\(name) callbacks=\(r?.callbacks ?? 0) frames=\(r?.frames ?? 0) rate=\(rate) buffer=\(r?.lastBufferFrames ?? 0)")
        if let e = engine.lastError { print("error=\(e)") }
        exit((r?.callbacks ?? 0) > 0 ? 0 : 1)
    default:
        FileHandle.standardError.write("usage: WakeWave [--selftest | --list | --probe SECONDS]\n".data(using: .utf8)!)
        exit(2)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
