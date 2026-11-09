// WakeWave: a menu bar app that keeps speakers awake by playing an inaudible 20 Hz tone straight to
// an output device through a Core Audio IOProc. Automatic mode follows macOS's default output device;
// a specific device can be picked instead.
// No polling: it reacts only to Core Audio property listeners, the system wake notification, and a
// single one-shot timer at the end of a chosen duration. Update checks run at launch, after wake and
// on request.
// CLI flags for testing: --selftest (tone and update math, no hardware), --list (output devices),
// --probe N (play to the default output for N seconds).
import Cocoa
import CoreAudio
import CryptoKit
import ServiceManagement

let toneFrequency = 20.0
// Signal strength choices. Amplitudes are 10^(dBFS/20), precomputed; --selftest checks them.
let signalLevels: [(dBFS: Int, title: String, amplitude: Float)] = [
    (-30, "Normal", 0.031622777), (-24, "Strong", 0.063095734), (-18, "Max", 0.12589254),
]
let wantedBufferFrames: UInt32 = 4096             // bigger IO buffer = fewer wakeups (~12/s at 48 kHz)
let durationChoices: [(minutes: Int?, title: String)] = [
    (nil, "Indefinitely"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"),
    (120, "2 hours"), (240, "4 hours"), (480, "8 hours"),
]
// Menu bar icon choices (SF Symbols available since macOS 11).
let iconChoices: [(symbol: String, title: String)] = [
    ("hifispeaker.fill", "Speaker"), ("hifispeaker", "Speaker Outline"), ("hifispeaker.2.fill", "Two Speakers"),
    ("speaker.wave.2.fill", "Speaker with Sound"), ("speaker.fill", "Small Speaker"),
    ("speaker.slash.fill", "Muted Speaker"), ("waveform", "Waveform"),
    ("dot.radiowaves.left.and.right", "Radio Waves"), ("music.note", "Music Note"), ("power", "Power"),
]
let defaultActiveColor = "#3DE155"
let updateRepo = "janmejayspurohit/WakeWave"
// Ed25519 public keys trusted for updates. Release DMGs are signed in CI with the private half of one
// of them (a GitHub secret). Rotating takes two releases: list old + new and sign with the old key,
// then switch the secret to the new key and drop the old one.
let updatePublicKeys = [
    "CgBQx/2IjgDTGqM292rr0uwABxa63t+Keh8HRc2xfXA=", "G5IdIih+7MXvM0FMbl5cCvsnQcW51mBRyfWttxqvuds=",
    "1X1hhMd8uiS1OZ8a8eCPusnVCsOjNZworz0KlfkP6CQ=", "qk54CQA1Pjp0s7yCjhJCwbQ1U72JqYq3t0LQKEcDGOA=",
    "j83ZefHSZW+TF/zM3w2FsfGdTAaQrxWZH7ZcvGCZE60=",
]
let systemObject = AudioObjectID(kAudioObjectSystemObject)

enum Pref {
    static let deviceUID = "deviceUID", deviceName = "deviceName"
    static let activeSymbol = "activeSymbol", inactiveSymbol = "inactiveSymbol"
    static let activeColor = "activeColor", inactiveColor = "inactiveColor"   // "#RRGGBB"
    static let signalLevel = "signalLevel"                                     // dBFS
    static let autoUpdate = "autoUpdate", lastUpdateCheck = "lastUpdateCheck"
}

let defaults: UserDefaults = {
    let d = UserDefaults.standard
    d.register(defaults: [Pref.activeSymbol: "hifispeaker.fill", Pref.inactiveSymbol: "hifispeaker.fill",
                          Pref.activeColor: defaultActiveColor, Pref.signalLevel: -30, Pref.autoUpdate: true])
    return d
}()

func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? .white
    return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                  Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}

func color(fromHex hex: String?) -> NSColor? {
    guard let hex = hex, hex.count == 7, hex.hasPrefix("#"), let v = Int(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let keepAliveGreen = color(fromHex: defaultActiveColor)!

func currentAmplitude() -> Float {
    let dBFS = defaults.integer(forKey: Pref.signalLevel)
    return (signalLevels.first { $0.dBFS == dBFS } ?? signalLevels[0]).amplitude
}

// MARK: - Tone

// One cycle of the sine, computed once per device start; rendering is then a table copy with no trig.
struct ToneGenerator {
    let table: [Float]
    var index = 0

    init(sampleRate: Double, amplitude: Float) {
        let n = max(Int((sampleRate / toneFrequency).rounded()), 4)   // 2400 samples at 48 kHz
        table = (0..<n).map { amplitude * Float(sin(2 * Double.pi * Double($0) / Double(n))) }
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
    init(sampleRate: Double, amplitude: Float) { generator = ToneGenerator(sampleRate: sampleRate, amplitude: amplitude) }

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

    // `end` is given only when resuming a timed session after an update relaunch.
    func turnOn(minutes: Int?, until end: Date? = nil) {
        resetToOff()
        enabled = true; activeMinutes = minutes
        if let m = minutes {
            let deadline = end ?? Date(timeIntervalSinceNow: TimeInterval(m * 60))
            until = deadline
            let t = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.turnOff() }
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
        defaults.set(uid, forKey: Pref.deviceUID)     // nil removes the key = Automatic
        defaults.set(name, forKey: Pref.deviceName)
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
        let r = Renderer(sampleRate: nominalSampleRate(id), amplitude: currentAmplitude())
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

// MARK: - Updates

// Checks the latest GitHub release at launch, after wake (at most every 12 hours) and on request.
// A newer WakeWave.dmg is installed only if its Ed25519 signature matches one of updatePublicKeys.
struct Release: Decodable {
    struct Asset: Decodable { let name: String; let browserDownloadUrl: URL }
    let tagName: String
    let assets: [Asset]
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}

func signatureIsValid(_ signature: Data, for file: Data, publicKeys: [String] = updatePublicKeys) -> Bool {
    publicKeys.contains { encoded in
        guard let raw = Data(base64Encoded: encoded),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: file)
    }
}

func runTool(_ path: String, _ arguments: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw UpdateError("\((path as NSString).lastPathComponent) exited with \(p.terminationStatus)")
    }
}

// Mounts the DMG read-only, copies WakeWave.app out of it, and checks it is the expected app and version.
func stageUpdate(dmg: URL, version: String, bundleID: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WakeWave-update-\(UUID().uuidString)")
    let mount = dir.appendingPathComponent("mount"), app = dir.appendingPathComponent("WakeWave.app")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try runTool("/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path, dmg.path)
    defer { try? runTool("/usr/bin/hdiutil", "detach", "-force", mount.path) }
    try runTool("/usr/bin/ditto", mount.appendingPathComponent("WakeWave.app").path, app.path)
    guard let b = Bundle(url: app), b.bundleIdentifier == bundleID,
          b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
        throw UpdateError("the downloaded app is not WakeWave \(version)")
    }
    return app
}

enum UpdateState: Equatable {
    case idle, checking, downloading, latest
    case available(String)                        // newer version found while auto-install is off
    case failed(String)                           // what went wrong (shown as a tooltip)
}

final class Updater {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private(set) var state = UpdateState.idle
    var onChange: (() -> Void)?
    var resumeArgument: () -> String = { "on" }   // the on/off state handed to the relaunched app

    // Release builds only: a local "dev" build never replaces itself.
    var isEnabled: Bool { version?.first?.isNumber == true }
    var busy: Bool { state == .checking || state == .downloading }
    var availableVersion: String? { if case .available(let v) = state { return v } else { return nil } }

    func check(manual: Bool = false, minInterval: TimeInterval = 0) {
        guard isEnabled, let version = version, !busy else { return }
        if !manual, Date().timeIntervalSince1970 - defaults.double(forKey: Pref.lastUpdateCheck) < minInterval { return }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            if manual { set(.failed("Move WakeWave to your Applications folder to get updates.")) }
            return
        }
        let previous = state
        set(.checking)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WakeWave/\(version)", forHTTPHeaderField: "User-Agent")
        fetch(request) { self.found($0, current: version, manual: manual, previous: previous) }
    }

    private func fetch(_ request: URLRequest, _ done: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok ? data : nil) }
        }.resume()
    }

    private func found(_ data: Data?, current: String, manual: Bool, previous: UpdateState) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = data, let release = try? decoder.decode(Release.self, from: data) else {
            return set(manual ? .failed("Couldn't reach GitHub. Try again later.") : previous)  // quiet when automatic
        }
        defaults.set(Date().timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isNewer(latest, than: current) else { return set(.latest) }
        guard manual || defaults.bool(forKey: Pref.autoUpdate) else { return set(.available(latest)) }
        let prefix = "https://github.com/\(updateRepo)/releases/download/"
        guard let dmg = release.assets.first(where: { $0.name == "WakeWave.dmg" })?.browserDownloadUrl,
              let sig = release.assets.first(where: { $0.name == "WakeWave.dmg.sig" })?.browserDownloadUrl,
              dmg.absoluteString.hasPrefix(prefix), sig.absoluteString.hasPrefix(prefix) else {
            return set(.failed("WakeWave \(latest) has no signed download."))
        }
        set(.downloading)
        fetch(URLRequest(url: sig)) { sigData in
            self.fetch(URLRequest(url: dmg)) { dmgData in self.install(latest, dmgData, sigData) }
        }
    }

    private func install(_ version: String, _ dmgData: Data?, _ sigData: Data?) {
        guard let file = dmgData, let text = sigData.map({ String(decoding: $0, as: UTF8.self) }),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              signatureIsValid(signature, for: file) else {
            return set(.failed("The WakeWave \(version) download failed verification and was discarded."))
        }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        DispatchQueue.global(qos: .utility).async {
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("WakeWave-\(version).dmg")
            let staged = Result { () throws -> URL in
                try file.write(to: dmg)
                return try stageUpdate(dmg: dmg, version: version, bundleID: bundleID)
            }
            DispatchQueue.main.async {
                switch staged {
                case .success(let app): self.replaceAndRelaunch(with: app, dmg: dmg, version: version)
                case .failure(let error): self.set(.failed("Couldn't install WakeWave \(version): \(error)"))
                }
            }
        }
    }

    private func replaceAndRelaunch(with app: URL, dmg: URL, version: String) {
        let target = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
        } catch {
            NSWorkspace.shared.open(dmg)              // fall back to a manual drag-install
            return set(.failed("Couldn't replace the app (\(error.localizedDescription)). "
                               + "WakeWave \(version) is open in Finder: drag it to Applications."))
        }
        try? FileManager.default.removeItem(at: dmg)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["--resume", resumeArgument()]
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.set(.failed("Updated to \(version). Quit and reopen WakeWave (\(error.localizedDescription))."))
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func set(_ new: UpdateState) { state = new; onChange?() }
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
    let engine = Engine(selectedUID: defaults.string(forKey: Pref.deviceUID),
                        selectedName: defaults.string(forKey: Pref.deviceName))
    let updater = Updater()
    var item: NSStatusItem!
    let menu = NSMenu()
    var menuIsOpen = false                         // rebuild items only while someone is looking
    var settings: SettingsWindow?                  // created the first time Settings is opened
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
        updater.onChange = { [weak self] in
            if self?.menuIsOpen == true { self?.rebuildMenu() }
            self?.settings?.sync()
        }
        updater.resumeArgument = { [weak self] in self?.resumeArgument() ?? "on" }
        resume(from: CommandLine.arguments)
        updater.check()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.updater.check(minInterval: 12 * 3600)
        }
    }

    // WakeWave starts on, unless an update relaunched it: then it continues the previous state,
    // passed as "--resume off", "--resume on" or "--resume <minutes>@<end time>".
    func resume(from args: [String]) {
        let state = args.count > 2 && args[1] == "--resume" ? args[2] : "on"
        let parts = state.split(separator: "@")
        if state == "off" {
            engine.turnOff()
        } else if parts.count == 2, let m = Int(parts[0]), let end = Double(parts[1]) {
            engine.turnOn(minutes: m, until: Date(timeIntervalSince1970: end))
        } else {
            engine.turnOn(minutes: nil)
        }
    }

    func resumeArgument() -> String {
        guard engine.enabled else { return "off" }
        guard let m = engine.activeMinutes, let end = engine.until else { return "on" }
        return "\(m)@\(Int(end.timeIntervalSince1970))"
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true; rebuildMenu() }   // fresh device list
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    // The menu bar icon is an image view tinting a template symbol, which renders sharper than the
    // button's own image. 14 pt is a whole size, so edges stay on pixels on 1x displays, and the
    // frame is set by hand to whole pixels: centered with floor(), never a half-pixel offset.
    func setUpStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: 20)
        guard let button = item.button else { return }
        button.toolTip = "WakeWave"
        button.setAccessibilityLabel("WakeWave")
        barIcon.onAppearanceChange = { [weak self] in self?.refresh() }
        button.addSubview(barIcon)
        button.postsFrameChangedNotifications = true    // re-center when the item or menu bar resizes
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                               queue: .main) { [weak self] _ in self?.centerBarIcon() }
    }

    func centerBarIcon() {
        guard let button = item.button, let s = barIcon.image?.size else { return }
        barIcon.frame = NSRect(x: floor((button.bounds.width - s.width) / 2),
                               y: floor((button.bounds.height - s.height) / 2), width: s.width, height: s.height)
    }

    func barSymbol(on: Bool) -> NSImage {
        let name = defaults.string(forKey: on ? Pref.activeSymbol : Pref.inactiveSymbol) ?? ""
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)!
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))!
    }

    // Icon and color come from Settings. With no inactive color chosen, the off icon is solid white
    // (solid black on a light menu bar). Solid colors, not labelColor, which in the menu bar is 90%
    // white blended with the wallpaper.
    func refresh() {
        let on = engine.enabled
        let shown = barSymbol(on: on), other = barSymbol(on: !on)
        barIcon.image = shown
        item.length = max(shown.size.width, other.size.width) + 4   // 2 pt each side, same width on and off
        let dark = [.darkAqua, .vibrantDark].contains(
            barIcon.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]))
        barIcon.contentTintColor = color(fromHex: defaults.string(forKey: on ? Pref.activeColor : Pref.inactiveColor))
            ?? (on ? keepAliveGreen : (dark ? .white : .black))
        centerBarIcon()
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
        if let v = updater.availableVersion {
            let update = NSMenuItem(title: "Install WakeWave \(v)", action: #selector(installUpdate), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
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

    @objc func installUpdate() { updater.check(manual: true) }

    @objc func openSettings() {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.show()
    }

    @objc func quitApp() { engine.turnOff(); NSApp.terminate(nil) }
}

// MARK: - Settings window

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private unowned let app: AppDelegate
    private let activeIcon = NSPopUpButton(), inactiveIcon = NSPopUpButton()
    private let activeColor = NSColorWell(), inactiveColor = NSColorWell()
    private let signal = NSPopUpButton()
    private let login = NSButton(checkboxWithTitle: "Launch WakeWave at login", target: nil, action: nil)
    private let autoUpdate = NSButton(checkboxWithTitle: "Install updates automatically", target: nil, action: nil)
    private let checkNow = NSButton(title: "Check Now", target: nil, action: nil)
    private let updateStatus = NSTextField(labelWithString: "")   // one word, so it never clips

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WakeWave Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        for popup in [activeIcon, inactiveIcon] {
            for choice in iconChoices {
                popup.addItem(withTitle: choice.title)
                popup.lastItem?.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
                popup.lastItem?.representedObject = choice.symbol
            }
            popup.target = self; popup.action = #selector(iconChanged)
        }
        for well in [activeColor, inactiveColor] {
            well.target = self; well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for level in signalLevels {
            signal.addItem(withTitle: "\(level.title) (\(level.dBFS) dBFS)")
            signal.lastItem?.tag = level.dBFS
        }
        signal.target = self; signal.action = #selector(signalChanged)
        login.target = self; login.action = #selector(loginChanged)
        autoUpdate.target = self; autoUpdate.action = #selector(autoUpdateChanged)
        checkNow.target = self; checkNow.action = #selector(checkForUpdates)
        updateStatus.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
        func note(_ text: String) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.textColor = .secondaryLabelColor
            f.preferredMaxLayoutWidth = 300
            return f
        }
        func row(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.spacing = 8
            return s
        }
        let empty = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [label("Icon when on:"), row([activeIcon, activeColor])],
            [label("Icon when off:"), row([inactiveIcon, inactiveColor])],
            [empty, restore],
            [label("Signal strength:"), signal],
            [empty, note("Raise it if your speaker still turns off.")],
            [label("Startup:"), login],
            [label("Updates:"), autoUpdate],
            [empty, row([checkNow, updateStatus])],
            [empty, note("Version \(app.updater.version ?? "dev")")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        for r in [3, 5, 6] { grid.row(at: r).topPadding = 12 }   // gaps between the sections
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        sync()
        NSColorPanel.shared.showsAlpha = false     // solid colors only
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Puts the saved settings and the updater's state into the controls.
    func sync() {
        for (popup, key) in [(activeIcon, Pref.activeSymbol), (inactiveIcon, Pref.inactiveSymbol)] {
            popup.selectItem(at: max(popup.indexOfItem(withRepresentedObject: defaults.string(forKey: key)), 0))
        }
        activeColor.color = color(fromHex: defaults.string(forKey: Pref.activeColor)) ?? keepAliveGreen
        inactiveColor.color = color(fromHex: defaults.string(forKey: Pref.inactiveColor)) ?? .white
        _ = signal.selectItem(withTag: defaults.integer(forKey: Pref.signalLevel))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoUpdate.state = defaults.bool(forKey: Pref.autoUpdate) ? .on : .off
        let u = app.updater
        autoUpdate.isEnabled = u.isEnabled
        checkNow.isEnabled = u.isEnabled && !u.busy
        let (word, tint, detail): (String, NSColor, String?) = {
            guard u.isEnabled else { return ("Dev build", .secondaryLabelColor, "Updates are off in development builds.") }
            switch u.state {
            case .idle: return ("", .secondaryLabelColor, nil)
            case .checking: return ("Checking…", .secondaryLabelColor, nil)
            case .downloading: return ("Updating…", .secondaryLabelColor, nil)
            case .latest: return ("Latest!", .systemGreen, "WakeWave \(u.version ?? "") is the latest version.")
            case .available(let v): return ("Update", .systemOrange, "WakeWave \(v) is available. Click Check Now to install it.")
            case .failed(let why): return ("Failed", .systemRed, why)
            }
        }()
        updateStatus.stringValue = word
        updateStatus.textColor = tint
        updateStatus.toolTip = detail
    }

    @objc private func iconChanged() {
        defaults.set(activeIcon.selectedItem?.representedObject as? String, forKey: Pref.activeSymbol)
        defaults.set(inactiveIcon.selectedItem?.representedObject as? String, forKey: Pref.inactiveSymbol)
        app.refresh()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        defaults.set(hexString(sender.color), forKey: sender === activeColor ? Pref.activeColor : Pref.inactiveColor)
        app.refresh()
    }

    @objc private func restoreDefaults() {
        for key in [Pref.activeSymbol, Pref.inactiveSymbol, Pref.activeColor, Pref.inactiveColor] {
            defaults.removeObject(forKey: key)
        }
        sync()
        app.refresh()
    }

    @objc private func signalChanged() {
        defaults.set(signal.selectedTag(), forKey: Pref.signalLevel)
        app.engine.restart()                       // the new level takes effect on the next start
    }

    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSAlert(error: error).runModal()
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        sync()
    }

    @objc private func autoUpdateChanged() { defaults.set(autoUpdate.state == .on, forKey: Pref.autoUpdate) }

    @objc private func checkForUpdates() { app.updater.check(manual: true) }

    func windowWillClose(_ notification: Notification) { NSColorPanel.shared.close() }
}

// MARK: - CLI test modes

func selfTest() -> Bool {
    var reasons: [String] = []
    for level in signalLevels {
        let exact = Float(pow(10.0, Double(level.dBFS) / 20.0))
        if abs(level.amplitude - exact) > 1e-6 { reasons.append("\(level.title) amplitude \(level.amplitude) != \(exact)") }
    }
    let amplitude = signalLevels[0].amplitude
    var report = ""
    for rate in [48000.0, 44100.0] {
        let channels = 2, total = Int(rate)            // one second
        var chunked = [Float](repeating: 0, count: total * channels)
        var single = chunked
        var g1 = ToneGenerator(sampleRate: rate, amplitude: amplitude)
        var g2 = ToneGenerator(sampleRate: rate, amplitude: amplitude)
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
        if abs(peak - amplitude) > amplitude * 0.01 { reasons.append("\(Int(rate)): peak \(peak)") }
        if abs(crossings - 40) > 1 { reasons.append("\(Int(rate)): crossings \(crossings)") }
        report += " \(Int(rate)):table=\(g1.table.count),peak=\(peak),crossings=\(crossings)"
    }
    // Update math: version order and signature checks (a throwaway key; no network).
    for (a, b, newer) in [("1.0.1", "1.0.0", true), ("1.10.0", "1.9.9", true), ("2", "1.9", true),
                          ("1.0", "1.0.0", false), ("1.0.0", "1.0.1", false), ("1.0.0", "1.0.0", false)]
        where isNewer(a, than: b) != newer { reasons.append("isNewer(\(a), \(b)) != \(newer)") }
    let key = Curve25519.Signing.PrivateKey(), file = Data("WakeWave".utf8)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    if let sig = try? key.signature(for: file) {
        if !signatureIsValid(sig, for: file, publicKeys: [publicKey]) { reasons.append("valid signature rejected") }
        if !signatureIsValid(sig, for: file, publicKeys: updatePublicKeys + [publicKey]) { reasons.append("second listed key rejected") }
        if signatureIsValid(sig, for: Data("WakeWav3".utf8), publicKeys: [publicKey]) { reasons.append("tampered file accepted") }
        if signatureIsValid(sig, for: file) { reasons.append("signature from an unlisted key accepted") }
    } else { reasons.append("could not sign") }
    if updatePublicKeys.isEmpty { reasons.append("no update keys") }
    for k in updatePublicKeys where (try? Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: k) ?? Data())) == nil {
        reasons.append("updatePublicKeys entry \(k) is not a valid Ed25519 key")
    }
    print(reasons.isEmpty ? "SELFTEST OK" + report + " updates:ok" : "SELFTEST FAIL " + reasons.joined(separator: "; "))
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
    case "--resume":                        // relaunched by an update; handled by AppDelegate
        break
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
