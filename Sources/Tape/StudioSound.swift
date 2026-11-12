@preconcurrency import AVFoundation
import AudioToolbox

/// Cleans up the voice, all on this Mac with audio units built into macOS
/// (nothing added to the app's size).
///
/// - **Clean:** Apple's voice isolation (the model behind FaceTime's Voice
///   Isolation) removes keyboard clicks, background noise and room echo,
///   then the voice is brought to podcast loudness.
/// - **Studio:** the same, plus a broadcast "podcast" tone: chest warmth,
///   a touch of body, a small dip for clarity, air on top, and gentle 1.7:1
///   compression. The settings are CrispVoice's (MIT), which were tuned in
///   blind tests against a commercial enhancer.
///
/// The result is cached next to the recording and swapped in for the
/// original audio at playback, export and sharing. The video file itself
/// is never changed.
enum StudioSound {
    enum Mode: String, Codable, CaseIterable {
        case clean, studio

        var title: String {
            switch self {
            case .clean: "Clean"
            case .studio: "Studio"
            }
        }
    }

    static let sampleRate = 48_000.0
    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    /// Final loudness, in LUFS (what CrispVoice and many podcasts use).
    private static let targetLoudness = -19.0

    static func cacheURL(for video: URL, mode: Mode) -> URL {
        video.deletingPathExtension().appendingPathExtension("\(mode.rawValue)-sound.m4a")
    }

    /// Every file this feature may have left next to a recording, including
    /// those of the earlier Studio Sound (removed in 0.4).
    static func cacheFiles(for video: URL) -> [URL] {
        Mode.allCases.map { cacheURL(for: video, mode: $0) }
            + ["studio.m4a", "studio2.m4a"].map { video.deletingPathExtension().appendingPathExtension($0) }
    }

    /// The processed audio, if it was already made.
    static func cached(for video: URL, mode: Mode?) -> AVURLAsset? {
        guard let mode else { return nil }
        let url = cacheURL(for: video, mode: mode)
        return FileManager.default.fileExists(atPath: url.path) ? AVURLAsset(url: url) : nil
    }

    /// Processes the recording's audio (about a second per minute) and
    /// returns the cached file.
    static func render(_ video: URL, mode: Mode, progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> URL {
        let output = cacheURL(for: video, mode: mode)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let task = Task.detached(priority: .userInitiated) {
            var samples = try await readMono(video)
            progress(0.15)
            var effects: [AVAudioUnit] = [isolation()]
            if mode == .studio { effects.append(tone()) }
            samples = try process(samples, through: effects) { progress(0.15 + $0 * 0.7) }
            if mode == .studio {
                // Compress at a known level, so quiet and loud recordings get
                // the same amount of it.
                apply(gainDB: Float(-24 - loudness(samples)), to: &samples)
                compress(&samples, thresholdDB: -20, ratio: 1.7, attack: 0.012, release: 0.22)
            }
            apply(gainDB: Float(targetLoudness - loudness(samples)), to: &samples)
            limit(&samples)
            let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: partial) }
            try write(samples, to: partial)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
            progress(1)
            return output
        }
        return try await task.value
    }

    // MARK: Effects

    private static func appleEffect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    private static func isolation() -> AVAudioUnitEffect {
        let unit = appleEffect(kAudioUnitSubType_AUSoundIsolation)
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        AudioUnitSetParameter(unit.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        return unit
    }

    /// CrispVoice's tone: bass shelf +3.5 dB at 160 Hz, +1.5 dB at 400 Hz,
    /// -1.5 dB at 280 Hz, high shelves +2.5 dB at 9 kHz and +1 dB at 10 kHz.
    private static func tone() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 6)
        let bands: [(AVAudioUnitEQFilterType, Float, Float, Float)] = [
            (.highPass, 60, 0, 0.7),  // desk thumps and rumble
            (.lowShelf, 160, 3.5, 1),
            (.parametric, 400, 1.5, 1.2),
            (.parametric, 280, -1.5, 1.6),
            (.highShelf, 9_000, 2.5, 1),
            (.highShelf, 10_000, 1, 1),
        ]
        for (band, (type, frequency, gain, bandwidth)) in zip(eq.bands, bands) {
            band.filterType = type
            band.frequency = frequency
            band.gain = gain
            band.bandwidth = bandwidth  // octaves
            band.bypass = false
        }
        return eq
    }

    // MARK: Reading and writing

    /// The recording's audio as 48 kHz mono, starting at the video's time
    /// zero (silence first if the microphone started late).
    private static func readMono(_ video: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriberError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriberError.noAudio }
        var samples: [Float] = []
        var first = true
        while let buffer = output.copyNextSampleBuffer() {
            if first {
                first = false
                let lead = Int(max(0, CMSampleBufferGetPresentationTimeStamp(buffer).seconds) * sampleRate)
                samples.append(contentsOf: repeatElement(0, count: lead))
            }
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: frames))
            samples.withUnsafeMutableBufferPointer { out in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4,
                                               destination: out.baseAddress! + start)
            }
        }
        if reader.status == .failed { throw reader.error ?? TranscriberError.noAudio }
        return samples
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var position = 0
        while position < samples.count {
            let count = min(chunk, samples.count - position)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + position, count: count) }
            try file.write(from: buffer)
            position += count
        }
    }

    // MARK: Processing

    /// Runs the samples through audio units faster than real time. The
    /// units' latency is trimmed, so the result lines up with the input.
    private static func process(_ input: [Float], through effects: [AVAudioUnit],
                                progress: (Double) -> Void) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let nodes: [AVAudioNode] = [player] + effects
        nodes.forEach(engine.attach)
        for (from, to) in zip(nodes, nodes.dropFirst()) { engine.connect(from, to: to, format: format) }
        engine.connect(nodes.last!, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let latency = Int((effects.map(\.auAudioUnit.latency).reduce(0, +) * sampleRate).rounded())
        // The input plus enough silence to flush the latency out.
        let padded = input.count + latency
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(padded, 1)))!
        source.frameLength = AVAudioFrameCount(padded)
        let channel = source.floatChannelData![0]
        input.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: input.count) }
        (channel + input.count).update(repeating: 0, count: latency)
        player.scheduleBuffer(source, completionHandler: nil)
        player.play()

        var output: [Float] = []
        output.reserveCapacity(padded)
        let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        while engine.manualRenderingSampleTime < padded {
            let frames = AVAudioFrameCount(min(Int64(rendered.frameCapacity), Int64(padded) - engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames, to: rendered) == .success else { break }
            output.append(contentsOf: UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength)))
            progress(Double(output.count) / Double(padded))
        }
        return Array(output.dropFirst(latency).prefix(input.count))
    }

    /// Speech loudness, close to LUFS: gated 400 ms blocks (without the
    /// K-weighting filter, which barely matters for a voice).
    static func loudness(_ samples: [Float]) -> Double {
        let size = Int(sampleRate * 0.4)
        var blocks: [Double] = []
        var i = 0
        while i + size <= samples.count {
            var sum = 0.0
            for s in samples[i..<(i + size)] { sum += Double(s) * Double(s) }
            blocks.append(sum / Double(size))
            i += size / 2  // 50% overlap
        }
        func db(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-12)) }
        let audible = blocks.filter { db($0) > -70 }
        guard !audible.isEmpty else { return targetLoudness }
        let average = audible.reduce(0, +) / Double(audible.count)
        let gated = audible.filter { db($0) > db(average) - 10 }
        return db(gated.reduce(0, +) / Double(max(gated.count, 1)))
    }

    private static func apply(gainDB: Float, to samples: inout [Float]) {
        let gain = pow(10, min(max(gainDB, -20), 30) / 20)
        for i in samples.indices { samples[i] *= gain }
    }

    /// A smooth feed-forward compressor, like ffmpeg's acompressor.
    private static func compress(_ samples: inout [Float], thresholdDB: Float, ratio: Float,
                                 attack: Float, release: Float) {
        let sr = Float(sampleRate)
        let attackCoefficient = exp(-1 / (attack * sr)), releaseCoefficient = exp(-1 / (release * sr))
        let slope = 1 - 1 / ratio
        var envelope: Float = 0
        for i in samples.indices {
            let level = abs(samples[i])
            let c = level > envelope ? attackCoefficient : releaseCoefficient
            envelope = c * envelope + (1 - c) * level
            let over = 20 * log10(max(envelope, 1e-9)) - thresholdDB
            if over > 0 { samples[i] *= pow(10, -over * slope / 20) }
        }
    }

    /// Leaves everything under -3 dB alone and bends louder peaks smoothly
    /// toward -1.5 dB, so nothing clips.
    private static func limit(_ samples: inout [Float]) {
        let knee: Float = 0.708, ceiling: Float = 0.84
        for i in samples.indices {
            let magnitude = abs(samples[i])
            guard magnitude > knee else { continue }
            let bent = knee + (ceiling - knee) * tanh((magnitude - knee) / (ceiling - knee))
            samples[i] = samples[i] < 0 ? -bent : bent
        }
    }
}
