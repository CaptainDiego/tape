@preconcurrency import AVFoundation
import AudioToolbox

/// Cleans up the voice, all on this Mac with audio units built into macOS
/// (nothing added to the app's size).
///
/// 1. Apple's voice isolation (the model behind FaceTime's Voice Isolation)
///    removes keyboard clicks, background noise and room echo.
/// 2. A broadcast "podcast" tone: chest warmth, a touch of body, a small dip
///    for clarity, air on top, and gentle 1.7:1 compression.
/// 3. Podcast loudness (-19 LUFS), with peaks kept under -1.5 dB.
///
/// The result is cached next to the recording and swapped in for the
/// original audio at playback, export and sharing. The video file itself
/// is never changed.
enum StudioSound {
    /// Only Studio for now; "clean" (isolation without the tone) was tried
    /// and dropped, and older edits that chose it get Studio.
    enum Mode: String, Codable, CaseIterable {
        case studio
    }

    static let sampleRate = 48_000.0
    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    /// Final loudness, in LUFS (what many podcasts use).
    private static let targetLoudness = -19.0

    static func cacheURL(for video: URL, mode: Mode) -> URL {
        video.deletingPathExtension().appendingPathExtension("\(mode.rawValue)-sound.m4a")
    }

    /// Every file this feature may have left next to a recording, including
    /// those of the earlier Studio Sound (removed in 0.4).
    static func cacheFiles(for video: URL) -> [URL] {
        Mode.allCases.map { cacheURL(for: video, mode: $0) }
            + ["clean-sound.m4a", "studio.m4a", "studio2.m4a"].map { video.deletingPathExtension().appendingPathExtension($0) }
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
            // Three streaming passes through temporary files, so memory stays
            // small however long the recording is.
            let temp = FileManager.default.temporaryDirectory
            let shaped = temp.appendingPathComponent("tape-\(UUID().uuidString).caf")
            let compressed = temp.appendingPathComponent("tape-\(UUID().uuidString).caf")
            let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
            defer { [shaped, compressed, partial].forEach { try? FileManager.default.removeItem(at: $0) } }

            // 1. Voice isolation and tone.
            let shapedLoudness = try await isolateAndShape(video, to: shaped) { progress($0 * 0.8) }
            // 2. Compress at a known level, so quiet and loud recordings get
            //    the same amount of it.
            var compressor = Compressor(thresholdDB: -20, ratio: 1.7, attack: 0.012, release: 0.22)
            let preGain = gain(-24 - shapedLoudness)
            let compressedLoudness = try transform(shaped, to: compressed, encoded: false) { samples in
                for i in samples.indices { samples[i] = compressor.process(samples[i] * preGain) }
            }
            progress(0.9)
            // 3. Podcast loudness, peaks kept under -1.5 dB, encoded to AAC.
            let finalGain = gain(targetLoudness - compressedLoudness)
            _ = try transform(compressed, to: partial, encoded: true) { samples in
                for i in samples.indices { samples[i] = limit(samples[i] * finalGain) }
            }
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

    /// The podcast tone: bass shelf +3.5 dB at 160 Hz, +1.5 dB at 400 Hz,
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

    // MARK: Passes

    /// Reads the recording's audio as 48 kHz mono, starting at the video's
    /// time zero (silence first if the microphone started late), runs it
    /// through voice isolation and the tone EQ, and writes it to `output`.
    /// Returns its loudness.
    private static func isolateAndShape(_ video: URL, to output: URL, progress: (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriberError.noAudio }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? TranscriberError.noAudio }

        var meter = LoudnessMeter()
        let chain = try OfflineChain(effects: [isolation(), tone()], output: output) { meter.add($0) }
        let total = max(duration * sampleRate, 1)
        var first = true
        while let sample = trackOutput.copyNextSampleBuffer() {
            if first {
                first = false
                let lead = Int(max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds) * sampleRate)
                if lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(lead)) {
                    silence.frameLength = AVAudioFrameCount(lead)
                    silence.floatChannelData![0].update(repeating: 0, count: lead)
                    chain.schedule(silence)
                }
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: buffer.floatChannelData![0])
            chain.schedule(buffer)
            try chain.renderScheduled()
            progress(min(Double(chain.scheduled) / total, 1))
        }
        if reader.status == .failed { throw reader.error ?? TranscriberError.noAudio }
        try chain.finish()
        return meter.loudness
    }

    /// Streams a float file through `body` in blocks into `output` (a float
    /// file, or AAC when `encoded`) and returns the loudness of the result.
    private static func transform(_ input: URL, to output: URL, encoded: Bool,
                                  _ body: (inout UnsafeMutableBufferPointer<Float>) -> Void) throws -> Double {
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let settings: [String: Any] = encoded
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
               AVEncoderBitRateKey: 160_000]
            : format.settings
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65_536)!
        var meter = LoudnessMeter()
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            var samples = UnsafeMutableBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            body(&samples)
            meter.add(UnsafeBufferPointer(samples))
            try file.write(from: buffer)
        }
        return meter.loudness
    }

    // MARK: Dynamics

    private static func gain(_ db: Double) -> Float {
        Float(pow(10, min(max(db, -20), 30) / 20))
    }

    /// Leaves everything under -3 dB alone and bends louder peaks smoothly
    /// toward -1.5 dB, so nothing clips.
    private static func limit(_ x: Float) -> Float {
        let knee: Float = 0.708, ceiling: Float = 0.84
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let bent = knee + (ceiling - knee) * tanh((magnitude - knee) / (ceiling - knee))
        return x < 0 ? -bent : bent
    }

    fileprivate static var monoFormat: AVAudioFormat { format }
}

/// A smooth feed-forward compressor, like ffmpeg's acompressor.
private struct Compressor {
    private let threshold: Float, slope: Float, attack: Float, release: Float
    private var envelope: Float = 0

    init(thresholdDB: Float, ratio: Float, attack: Float, release: Float) {
        let sr = Float(StudioSound.sampleRate)
        threshold = thresholdDB
        slope = 1 - 1 / ratio
        self.attack = exp(-1 / (attack * sr))
        self.release = exp(-1 / (release * sr))
    }

    mutating func process(_ x: Float) -> Float {
        let level = abs(x)
        let c = level > envelope ? attack : release
        envelope = c * envelope + (1 - c) * level
        let over = 20 * log10(max(envelope, 1e-9)) - threshold
        return over > 0 ? x * pow(10, -over * slope / 20) : x
    }
}

/// Speech loudness, close to LUFS: gated 400 ms blocks with 50% overlap
/// (without the K-weighting filter, which barely matters for a voice).
/// Keeps only one number per 200 ms, so it streams.
private struct LoudnessMeter {
    private let step = Int(StudioSound.sampleRate * 0.2)
    private var sum = 0.0
    private var count = 0
    private var steps: [Double] = []  // mean square of each 200 ms

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            sum += Double(s) * Double(s)
            count += 1
            if count == step {
                steps.append(sum / Double(count))
                sum = 0
                count = 0
            }
        }
    }

    var loudness: Double {
        let blocks = zip(steps, steps.dropFirst()).map { ($0 + $1) / 2 }
        func db(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-12)) }
        let audible = blocks.filter { db($0) > -70 }
        guard !audible.isEmpty else { return -19 }
        let average = audible.reduce(0, +) / Double(audible.count)
        let gated = audible.filter { db($0) > db(average) - 10 }
        return db(gated.reduce(0, +) / Double(max(gated.count, 1)))
    }
}

/// Audio units run faster than real time: buffers go in, the processed
/// audio is written to a float file, with the units' latency trimmed off so
/// it lines up with the input.
private final class OfflineChain {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let file: AVAudioFile
    private let rendered: AVAudioPCMBuffer
    private let latency: AVAudioFramePosition
    private var toSkip: AVAudioFramePosition
    private let onSamples: (UnsafeBufferPointer<Float>) -> Void
    private(set) var scheduled: AVAudioFramePosition = 0

    init(effects: [AVAudioUnit], output: URL, onSamples: @escaping (UnsafeBufferPointer<Float>) -> Void) throws {
        let format = StudioSound.monoFormat
        self.onSamples = onSamples
        let nodes: [AVAudioNode] = [player] + effects
        nodes.forEach(engine.attach)
        for (from, to) in zip(nodes, nodes.dropFirst()) { engine.connect(from, to: to, format: format) }
        engine.connect(nodes.last!, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.play()
        latency = AVAudioFramePosition((effects.map(\.auAudioUnit.latency).reduce(0, +) * StudioSound.sampleRate).rounded())
        toSkip = latency
        rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
        scheduled += AVAudioFramePosition(buffer.frameLength)
    }

    /// Renders what's been scheduled, staying a little behind so the player
    /// never runs dry mid-stream.
    func renderScheduled() throws { try render(upTo: max(0, scheduled - 8192)) }

    /// Renders the rest, with silence to flush the latency out.
    func finish() throws {
        let tail = Int(latency)
        if tail > 0, let silence = AVAudioPCMBuffer(pcmFormat: StudioSound.monoFormat, frameCapacity: AVAudioFrameCount(tail)) {
            silence.frameLength = AVAudioFrameCount(tail)
            silence.floatChannelData![0].update(repeating: 0, count: tail)
            player.scheduleBuffer(silence, completionHandler: nil)
        }
        try render(upTo: scheduled + latency)
        engine.stop()
    }

    private func render(upTo target: AVAudioFramePosition) throws {
        while engine.manualRenderingSampleTime < target {
            let frames = AVAudioFrameCount(min(Int64(rendered.frameCapacity), target - engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames, to: rendered) == .success else { break }
            var samples = UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength))
            if toSkip > 0 {
                let skip = min(Int(toSkip), samples.count)
                toSkip -= AVAudioFramePosition(skip)
                samples = UnsafeBufferPointer(rebasing: samples[skip...])
                if samples.isEmpty { continue }
            }
            let out = AVAudioPCMBuffer(pcmFormat: StudioSound.monoFormat, frameCapacity: AVAudioFrameCount(samples.count))!
            out.frameLength = AVAudioFrameCount(samples.count)
            out.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
            onSamples(samples)
            try file.write(from: out)
        }
    }
}
