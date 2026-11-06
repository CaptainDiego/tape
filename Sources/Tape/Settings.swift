import AppKit
import AVFoundation

/// Recording presets. Above 1080p we switch to HEVC because H.264 encoders
/// top out around 4096 pixels wide.
enum Quality: String, CaseIterable {
    case p720_30, p1080_30, p1080_60, native_60

    var title: String {
        switch self {
        case .p720_30: "720p · 30 fps"
        case .p1080_30: "1080p · 30 fps"
        case .p1080_60: "1080p · 60 fps"
        case .native_60: "Native resolution · 60 fps"
        }
    }

    var fps: Int {
        switch self {
        case .p720_30, .p1080_30: 30
        case .p1080_60, .native_60: 60
        }
    }

    private var targetHeight: Int? {
        switch self {
        case .p720_30: 720
        case .p1080_30, .p1080_60: 1080
        case .native_60: nil
        }
    }

    var codec: AVVideoCodecType { self == .native_60 ? .hevc : .h264 }

    /// Output size in pixels for an area of the screen, keeping its aspect
    /// ratio and never scaling up.
    func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let pw = Int((points.width * scale).rounded())
        let ph = Int((points.height * scale).rounded())
        guard let h = targetHeight, h < ph else { return (pw & ~1, ph & ~1) }
        let w = Int((Double(pw) * Double(h) / Double(ph)).rounded())
        return (w & ~1, h & ~1)
    }
}

/// User choices, stored in UserDefaults. For camera and mic, nil means "none";
/// before the user picks anything we use the system default device.
final class Settings {
    private let defaults = UserDefaults.standard

    static let recordingsDir = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tape", isDirectory: true)

    var displayID: CGDirectDisplayID {
        get {
            let stored = CGDirectDisplayID(defaults.integer(forKey: "displayID"))
            return Devices.displays().contains { $0.id == stored } ? stored : CGMainDisplayID()
        }
        set { defaults.set(Int(newValue), forKey: "displayID") }
    }

    var cameraID: String? {
        get { deviceID(forKey: "cameraID", fallback: AVCaptureDevice.default(for: .video)) }
        set { defaults.set(newValue ?? "", forKey: "cameraID") }
    }

    var micID: String? {
        get { deviceID(forKey: "micID", fallback: AVCaptureDevice.default(for: .audio)) }
        set { defaults.set(newValue ?? "", forKey: "micID") }
    }

    var quality: Quality {
        get { Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .p1080_30 }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    var bubbleShape: BubbleShape {
        get { BubbleShape(rawValue: defaults.string(forKey: "bubbleShape") ?? "") ?? .roundedSquare }
        set { defaults.set(newValue.rawValue, forKey: "bubbleShape") }
    }

    private func deviceID(forKey key: String, fallback: AVCaptureDevice?) -> String? {
        guard let stored = defaults.string(forKey: key) else { return fallback?.uniqueID }
        if stored.isEmpty { return nil }
        // A device that was unplugged counts as "none" until it comes back.
        return AVCaptureDevice(uniqueID: stored) != nil ? stored : nil
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return recordingsDir.appendingPathComponent("Tape \(formatter.string(from: Date())).mp4")
    }
}

enum Devices {
    static func cameras() -> [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices)
    }

    static func microphones() -> [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices)
    }

    static func displays() -> [(id: CGDirectDisplayID, name: String)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (id, screen.localizedName)
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }
    }

    private static func unique(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }
}
