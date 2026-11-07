@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox

/// "Studio Sound": makes a laptop-mic recording sound like it was made on a
/// good studio microphone. Everything runs on this Mac with audio units
/// built into macOS, so it adds nothing to the app's size.
///
/// 1. Apple's voice isolation (the model behind FaceTime's Voice Isolation)
///    removes background noise, hum and room echo.
/// 2. Mic matching: the voice's tonal balance is measured and an EQ moves
///    it toward that of a voice recorded on a studio mic (the standard
///    long-term speech spectrum, with a little warmth, presence and air).
///    Each recording gets its own correction, so a dark laptop mic gets
///    brighter and a thin headset gets fuller.
/// 3. A light compressor, so the voice stays natural and dynamic.
/// 4. Loudness is set to about -16 LUFS (what YouTube and podcasts use),
///    with peaks kept under 0 dB.
///
/// The result is saved next to the recording as "<name>.studio2.m4a" and
/// swapped in for the original audio at playback and export.
enum StudioSound {
    static let sampleRate = 48_000.0

    static func cacheURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("studio2.m4a")
    }

    /// Processes the recording's audio and returns the cached file.
    static func render(_ video: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let output = cacheURL(for: video)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let task = Task.detached(priority: .userInitiated) {
            let temp = FileManager.default.temporaryDirectory
            let isolated = temp.appendingPathComponent(UUID().uuidString + ".caf")
            let polished = temp.appendingPathComponent(UUID().uuidString + ".caf")
            defer {
                try? FileManager.default.removeItem(at: isolated)
                try? FileManager.default.removeItem(at: polished)
            }
            let spectrum = try await isolate(video, to: isolated) { progress($0 * 0.5) }
            let eq = spectrum.matchingEQ()
            if ProcessInfo.processInfo.environment["TAPE_DEBUG"] != nil {
                print("mic matching EQ:", eq.map { "\(Int($0.frequency)) Hz \(String(format: "%+.1f", $0.gain))" }
                    .joined(separator: ", "))
            }
            let loudness = try polish(isolated, eq: eq, to: polished) { progress(0.5 + $0 * 0.4) }
            let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
            try normalize(polished, loudness: loudness, to: partial)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: partial, to: output)
            // Drop the file from the first version of Studio Sound.
            try? FileManager.default.removeItem(at: video.deletingPathExtension().appendingPathExtension("studio.m4a"))
            progress(1)
            return output
        }
        return try await task.value
    }

    private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    // MARK: Pass 1: voice isolation

    /// Reads the recording's audio, isolates the voice into `output`, and
    /// measures the voice's spectrum on the way.
    private static func isolate(_ video: URL, to output: URL, progress: (Double) -> Void) async throws -> Spectrum {
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

        let isolation = AVAudioUnitEffect(audioComponentDescription: appleEffect(kAudioUnitSubType_AUSoundIsolation))
        AudioUnitSetParameter(isolation.audioUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        AudioUnitSetParameter(isolation.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0,
                              AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        var spectrum = Spectrum()
        let chain = try OfflineChain(effects: [isolation], output: output) { spectrum.add($0) }

        let total = max(duration * sampleRate, 1)
        var first = true
        while let sample = trackOutput.copyNextSampleBuffer() {
            // Silence first if the microphone started after the picture, so
            // the processed audio lines up with the video from time zero.
            if first {
                first = false
                let lead = Int(max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds) * sampleRate)
                if lead > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(lead)) {
                    silence.frameLength = AVAudioFrameCount(lead)
                    memset(silence.floatChannelData![0], 0, lead * 4)
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
        return spectrum
    }

    // MARK: Pass 2: mic matching EQ and compression

    /// Runs the isolated voice through the EQ and compressor into `output`
    /// and returns its loudness in dB.
    private static func polish(_ input: URL, eq gains: [(frequency: Float, gain: Float)], to output: URL,
                               progress: (Double) -> Void) throws -> Double {
        let eq = AVAudioUnitEQ(numberOfBands: gains.count + 1)
        eq.bands[0].filterType = .highPass  // rumble and desk thumps
        eq.bands[0].frequency = 70
        eq.bands[0].bypass = false
        for (band, setting) in zip(eq.bands.dropFirst(), gains) {
            band.filterType = .parametric
            band.frequency = setting.frequency
            band.bandwidth = 0.75  // octaves
            band.gain = setting.gain
            band.bypass = false
        }

        // Light compression: evens out the loudest moments without the
        // squashed "radio" sound.
        let compressor = AVAudioUnitEffect(audioComponentDescription: appleEffect(kAudioUnitSubType_DynamicsProcessor))
        for (parameter, value) in [(kDynamicsProcessorParam_Threshold, -22.0), (kDynamicsProcessorParam_HeadRoom, 14.0),
                                   (kDynamicsProcessorParam_AttackTime, 0.01), (kDynamicsProcessorParam_ReleaseTime, 0.2),
                                   // Lowers the faint room tone between
                                   // sentences a little, without dead silence.
                                   (kDynamicsProcessorParam_ExpansionThreshold, -50.0),
                                   (kDynamicsProcessorParam_ExpansionRatio, 1.5)] {
            AudioUnitSetParameter(compressor.audioUnit, parameter, kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
        }

        var meter = LoudnessMeter(sampleRate: sampleRate)
        let chain = try OfflineChain(effects: [eq, compressor], output: output) { meter.add($0) }
        let source = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Double(max(source.length, 1))
        while source.framePosition < source.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)!
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            chain.schedule(buffer)
            try chain.renderScheduled()
            progress(Double(source.framePosition) / total)
        }
        try chain.finish()
        return meter.loudness
    }

    // MARK: Pass 3: loudness

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

    fileprivate static func appleEffect(_ subtype: OSType) -> AudioComponentDescription {
        AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    fileprivate static var monoFormat: AVAudioFormat { format }
}

/// Audio effects run faster than real time: buffers go in, the processed
/// audio is written to a float file, delayed by nothing (the effects'
/// latency is trimmed off).
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

    /// Renders what's been scheduled, keeping a little ahead so the player
    /// never runs dry mid-stream.
    func renderScheduled() throws { try render(upTo: max(0, scheduled - 8192)) }

    func finish() throws {
        try render(upTo: scheduled + latency)
        engine.stop()
    }

    private func render(upTo target: AVAudioFramePosition) throws {
        let format = StudioSound.monoFormat
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
            onSamples(samples)
            try file.write(from: out)
        }
    }
}

/// The voice's average spectrum, measured while it's speaking, and the EQ
/// that moves it toward a studio-mic voice.
private struct Spectrum {
    private static let size = 4096
    private static let log2Size = vDSP_Length(12)
    /// Centers of the EQ bands, 2/3 of an octave apart.
    static let centers: [Float] = [100, 160, 250, 400, 630, 1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 14_000]

    /// Long-term average speech spectrum (Byrne et al. 1994, both sexes),
    /// dB per third octave: what a voice sounds like on a flat studio mic.
    private static let speech: [(Float, Float)] = [
        (63, 38.6), (80, 43.5), (100, 54.4), (125, 57.7), (160, 56.8), (200, 58.2), (250, 59.7), (315, 60.0),
        (400, 62.1), (500, 62.1), (630, 60.5), (800, 56.8), (1_000, 53.7), (1_250, 53.0), (1_600, 52.0),
        (2_000, 48.7), (2_500, 48.1), (3_150, 46.8), (4_000, 45.6), (5_000, 44.5), (6_300, 44.3), (8_000, 43.7),
        (10_000, 43.4), (12_500, 41.3), (16_000, 40.7),
    ]
    /// The "studio mic" flavor on top: some warmth from close-miking,
    /// less boxiness, presence and air.
    private static let flavor: [Float] = [2.5, 2.5, 0.5, -1, -0.5, 0, 0, 1, 2, 2, 2.5, 1.5]

    private let setup = vDSP_create_fftsetup(Spectrum.log2Size, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: Spectrum.size)
    private var pending: [Float] = []
    private var frames: [(level: Float, bands: [Float])] = []
    private let bins: [Range<Int>]

    init() {
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        let binWidth = Float(StudioSound.sampleRate) / Float(Self.size)
        bins = Self.centers.map { center in
            let low = Int((center / pow(2, 1 / 3) / binWidth).rounded())
            let high = Int((center * pow(2, 1 / 3) / binWidth).rounded())
            return max(low, 1)..<max(high, low + 1)
        }
    }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        while pending.count >= Self.size {
            analyze(Array(pending[0..<Self.size]))
            pending.removeFirst(Self.size)
        }
    }

    private mutating func analyze(_ frame: [Float]) {
        var meanSquare: Float = 0
        vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(Self.size))
        var windowed = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))

        let half = Self.size / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        let bands = bins.map { range in power[range.clamped(to: 1..<half)].reduce(0, +) }
        frames.append((10 * log10(max(meanSquare, 1e-12)), bands))
    }

    /// Gain per EQ band, in dB. Only the voice's own frames count, the
    /// overall level is left alone (only the balance changes), and the
    /// corrections are limited so nothing gets harsh or boomy.
    func matchingEQ() -> [(frequency: Float, gain: Float)] {
        let levels = frames.map(\.level).sorted()
        guard levels.count > 10 else { return Self.centers.map { ($0, 0) } }
        let loud = levels[Int(Double(levels.count - 1) * 0.95)]
        let speaking = frames.filter { $0.level > max(loud - 25, -70) }
        guard !speaking.isEmpty else { return Self.centers.map { ($0, 0) } }

        var difference: [Float] = []
        for (i, center) in Self.centers.enumerated() {
            let average = speaking.map { $0.bands[i] }.reduce(0, +) / Float(speaking.count)
            let measured = 10 * log10(max(average, 1e-20))
            difference.append(Self.target(at: center) + Self.flavor[i] - measured)
        }
        // Match the shape, not the level: the 250 Hz–4 kHz bands average to 0.
        let core = difference[2...8]
        let offset = core.reduce(0, +) / Float(core.count)
        let centered = difference.map { $0 - offset }
        // Smooth neighbors so the curve stays broad and musical.
        let smoothed = centered.indices.map { i -> Float in
            let left = centered[max(i - 1, 0)], right = centered[min(i + 1, centered.count - 1)]
            return 0.25 * left + 0.5 * centered[i] + 0.25 * right
        }
        return zip(Self.centers, smoothed).map { center, gain in
            let limit: ClosedRange<Float> = center <= 160 ? -5...3 : center >= 10_000 ? -6...6 : -8...8
            return (center, min(max(gain * 0.8, limit.lowerBound), limit.upperBound))
        }
    }

    /// The speech spectrum at a frequency, interpolated on a log scale.
    private static func target(at frequency: Float) -> Float {
        guard let upper = speech.firstIndex(where: { $0.0 >= frequency }) else { return speech.last!.1 }
        guard upper > 0 else { return speech[0].1 }
        let (f0, v0) = speech[upper - 1], (f1, v1) = speech[upper]
        let t = log(frequency / f0) / log(f1 / f0)
        return v0 + (v1 - v0) * t
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
