@preconcurrency import AVFoundation
import AudioToolbox

/// "Studio Sound": makes a laptop-mic recording sound like a voice-over.
/// Everything runs on this Mac with audio units built into macOS, so it adds
/// nothing to the app's size:
///
/// 1. Apple's voice isolation (the ML model behind FaceTime's Voice
///    Isolation) removes background noise, hum, keyboard and room echo.
/// 2. EQ: cuts rumble and boominess, adds a little presence.
/// 3. A compressor evens out loud and quiet moments; a gentle gate keeps
///    the pauses quiet.
/// 4. Loudness is brought to a consistent level (about -16 LUFS, what
///    YouTube and podcasts use), with peaks kept under 0 dB.
///
/// The result is saved next to the recording as "<name>.studio.m4a" and
/// swapped in for the original audio at playback and export.
enum StudioSound {
    static let sampleRate = 48_000.0

    static func cacheURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("studio.m4a")
    }

    static func isRendered(for video: URL) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(for: video).path)
    }

    /// Processes the recording's audio and returns the cached file.
    static func render(_ video: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let output = cacheURL(for: video)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let task = Task.detached(priority: .userInitiated) {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: temp) }
            let loudness = try await process(video, to: temp, progress: { progress($0 * 0.9) })
            let partial = output.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).m4a")
            try normalize(temp, loudness: loudness, to: partial)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
            progress(1)
            return output
        }
        return try await task.value
    }

    // MARK: Processing

    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Runs the audio through the effect chain into `output` (float CAF)
    /// and returns its measured loudness in dB.
    private static func process(_ video: URL, to output: URL, progress: (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriberError.noAudio
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? TranscriberError.noAudio }

        // The chain.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let isolation = AVAudioUnitEffect(audioComponentDescription: appleEffect(kAudioUnitSubType_AUSoundIsolation))
        AudioUnitSetParameter(isolation.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        AudioUnitSetParameter(isolation.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)

        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let bands: [(AVAudioUnitEQFilterType, Float, Float, Float)] = [
            (.highPass, 80, 0, 0.7),       // rumble, desk thumps
            (.parametric, 250, -2.5, 1.2), // boominess of small rooms
            (.parametric, 3_500, 2.5, 1.5),// presence: clearer consonants
            (.highShelf, 10_000, 1.5, 0),  // a little air
        ]
        for (band, (type, frequency, gain, bandwidth)) in zip(eq.bands, bands) {
            band.filterType = type
            band.frequency = frequency
            band.gain = gain
            if bandwidth > 0 { band.bandwidth = bandwidth }
            band.bypass = false
        }

        let compressor = AVAudioUnitEffect(audioComponentDescription: appleEffect(kAudioUnitSubType_DynamicsProcessor))
        for (parameter, value) in [(kDynamicsProcessorParam_Threshold, -28.0), (kDynamicsProcessorParam_HeadRoom, 8.0),
                                   (kDynamicsProcessorParam_AttackTime, 0.004), (kDynamicsProcessorParam_ReleaseTime, 0.12),
                                   // A gentle gate: whatever noise is left
                                   // between sentences is pushed further down.
                                   (kDynamicsProcessorParam_ExpansionThreshold, -50.0),
                                   (kDynamicsProcessorParam_ExpansionRatio, 3.0)] {
            AudioUnitSetParameter(compressor.audioUnit, parameter, kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
        }

        let nodes: [AVAudioNode] = [player, isolation, eq, compressor]
        nodes.forEach(engine.attach)
        for (from, to) in zip(nodes, nodes.dropFirst()) { engine.connect(from, to: to, format: format) }
        engine.connect(compressor, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        player.play()
        defer { engine.stop() }

        // The effects delay the sound a little; drop that much from the start
        // so the voice stays in sync with the picture.
        let latency = [isolation.auAudioUnit, eq.auAudioUnit, compressor.auAudioUnit].map(\.latency).reduce(0, +)
        var toSkip = AVAudioFramePosition((latency * sampleRate).rounded())

        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var meter = LoudnessMeter(sampleRate: sampleRate)
        var scheduled: AVAudioFramePosition = 0
        let total = max(duration * sampleRate, 1)

        func render(upTo target: AVAudioFramePosition) throws {
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
                let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
                out.frameLength = AVAudioFrameCount(samples.count)
                out.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
                meter.add(samples)
                try file.write(from: out)
            }
        }

        // Silence first, if the microphone started after the picture, so
        // the processed audio lines up with the video from time zero.
        var first = true
        while let sample = trackOutput.copyNextSampleBuffer() {
            if first {
                first = false
                let lead = AVAudioFramePosition(max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds) * sampleRate)
                if lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(lead)) {
                    silence.frameLength = AVAudioFrameCount(lead)
                    memset(silence.floatChannelData![0], 0, Int(lead) * 4)
                    player.scheduleBuffer(silence, completionHandler: nil)
                    scheduled += lead
                }
            }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: buffer.floatChannelData![0])
            player.scheduleBuffer(buffer, completionHandler: nil)
            scheduled += AVAudioFramePosition(frames)
            // Keep a little scheduled ahead of what's rendered.
            try render(upTo: max(0, scheduled - 8192))
            progress(min(Double(scheduled) / total, 1))
        }
        if reader.status == .failed { throw reader.error ?? TranscriberError.noAudio }
        try render(upTo: scheduled + AVAudioFramePosition((latency * sampleRate).rounded()))
        return meter.loudness
    }

    /// Applies the gain that brings the voice to the target loudness, keeps
    /// peaks just under full scale, and encodes AAC.
    private static func normalize(_ input: URL, loudness: Double, to output: URL) throws {
        let target = -16.0  // dB, roughly LUFS for speech
        let gain = Float(pow(10, min(max(target - loudness, -12), 24) / 20))
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 65_536)!
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            let samples = buffer.floatChannelData![0]
            for i in 0..<Int(buffer.frameLength) {
                samples[i] = softLimit(samples[i] * gain)
            }
            try file.write(from: buffer)
        }
    }

    /// Leaves everything under 0.8 alone and bends louder peaks smoothly
    /// toward 0.98, so nothing clips.
    private static func softLimit(_ x: Float) -> Float {
        let knee: Float = 0.8, ceiling: Float = 0.98
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let over = (magnitude - knee) / (ceiling - knee)
        return (knee + (ceiling - knee) * tanh(over)) * (x < 0 ? -1 : 1)
    }

    private static func appleEffect(_ subtype: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0)
    }
}

/// Speech loudness, measured like LUFS (gated 400 ms blocks) without the
/// K-weighting filter, which is close enough for a voice.
private struct LoudnessMeter {
    private let blockSize: Int
    private var sum = 0.0
    private var count = 0
    private var blocks: [Double] = []  // mean square of each block

    init(sampleRate: Double) { blockSize = Int(sampleRate * 0.4) }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            sum += Double(s) * Double(s)
            count += 1
            if count == blockSize {
                blocks.append(sum / Double(count))
                sum = 0
                count = 0
            }
        }
    }

    var loudness: Double {
        func db(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-12)) }
        let audible = blocks.filter { db($0) > -60 }
        guard !audible.isEmpty else { return -16 }
        let average = audible.reduce(0, +) / Double(audible.count)
        let speech = audible.filter { db($0) > db(average) - 10 }
        return db(speech.reduce(0, +) / Double(max(speech.count, 1)))
    }
}
