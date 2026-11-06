@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation

enum TranscriberError: LocalizedError {
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudio: "This recording has no audio track (was the microphone set to None?)."
        }
    }
}

/// Runs Parakeet v3 on this Mac. It loads the same model files Murmur
/// downloaded, and only goes online if they're missing.
actor Transcriber {
    static let shared = Transcriber()
    static let modelName = "parakeet-tdt-0.6b-v3"

    private var loading: Task<(AsrManager, Int), Error>?

    func transcribe(_ video: URL) async throws -> Transcript {
        let (manager, decoderLayers) = try await loadedManager()

        // FluidAudio reads audio with AVAudioFile, which doesn't open an MP4
        // that also holds video, so pull the audio out first.
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        defer { try? FileManager.default.removeItem(at: audio) }
        let offset = try await Self.extractAudio(from: video, to: audio)

        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let tokens = (result.tokenTimings ?? []).map { (text: $0.token, start: $0.startTime, end: $0.endTime) }
        return Transcript(model: Self.modelName, words: Transcript.words(fromTokens: tokens, offset: offset))
    }

    /// Loads the model once. Two windows asking at the same time share the
    /// same load instead of each starting one.
    private func loadedManager() async throws -> (AsrManager, Int) {
        if let loading { return try await loading.value }
        let task = Task { () throws -> (AsrManager, Int) in
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine

            let directory = AsrModels.defaultCacheDirectory(for: .v3)
            let models: AsrModels
            if AsrModels.modelsExist(at: directory, version: .v3),
               let local = try? AsrModels.loadLocal(from: directory, version: .v3, configuration: configuration) {
                models = local
            } else {
                models = try await AsrModels.downloadAndLoad(configuration: configuration, version: .v3)
            }
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return (asr, await asr.decoderLayerCount)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil  // let the next attempt retry
            throw error
        }
    }

    /// Writes the recording's audio as 16 kHz mono float to `output` and
    /// returns where that audio starts in the video, in seconds (the mic can
    /// start a moment after the picture).
    private static func extractAudio(from video: URL, to output: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriberError.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? TranscriberError.noAudio }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var offset: TimeInterval?
        do {
            let file = try AVAudioFile(forWriting: output, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            while let sample = trackOutput.copyNextSampleBuffer() {
                if offset == nil {
                    offset = max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
                else { continue }
                buffer.frameLength = frames
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: Int(frames) * 4,
                                           destination: buffer.floatChannelData![0])
                try file.write(from: buffer)
            }
        } // The file is closed when it goes out of scope here.
        if reader.status == .failed { throw reader.error ?? TranscriberError.noAudio }
        return offset ?? 0
    }
}
