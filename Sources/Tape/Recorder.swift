import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay, notRecording

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Couldn't find the screen to record."
        case .notRecording: "Nothing is being recorded."
        }
    }
}

/// Records one display plus the microphone straight to an MP4, using
/// ScreenCaptureKit's built-in file writer (macOS 15+). The camera isn't
/// recorded separately: its floating bubble is on screen, so it's captured
/// as part of the display.
final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate, @unchecked Sendable {
    /// Called when capture ends without us asking, e.g. the user clicked
    /// "Stop" in the system's screen-recording indicator.
    var onUnexpectedStop: (@MainActor (Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var fileURL: URL?
    private let sampleQueue = DispatchQueue(label: "tape.recorder.samples")

    private let lock = NSLock()
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var finishResult: Result<Void, Error>?

    /// - Parameters:
    ///   - region: area to record in the display's own points (top-left
    ///     origin), or nil for the whole display.
    ///   - excluding: our own helper windows (e.g. the outline around the
    ///     region) that shouldn't appear in the video.
    func start(displayID: CGDirectDisplayID, region: CGRect?, micID: String?, quality: Quality,
               excluding windowIDs: [CGWindowID], to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
        else { throw RecorderError.noDisplay }

        let hidden = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: hidden)
        let config = SCStreamConfiguration()
        let fullArea = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let area = region ?? fullArea
        if region != nil { config.sourceRect = area }
        let pixelsPerPoint = CGFloat(CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? display.width)
            / CGFloat(display.width)
        let size = quality.pixelSize(points: area.size, scale: pixelsPerPoint)
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        config.showsCursor = true
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // The file writer does the real work, but the stream still expects
        // an output for each media type it produces.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if micID != nil {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        let outputConfig = SCRecordingOutputConfiguration()
        outputConfig.outputURL = url
        outputConfig.outputFileType = .mp4
        outputConfig.videoCodecType = outputConfig.availableVideoCodecTypes.contains(quality.codec)
            ? quality.codec : .h264
        let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
        try stream.addRecordingOutput(output)

        lock.withLock {
            finishResult = nil
            finishContinuation = nil
        }
        try await stream.startCapture()
        self.stream = stream
        self.recordingOutput = output
        self.fileURL = url
    }

    /// Stops capture and returns the finished file once it's written.
    func stop() async throws -> URL {
        guard let stream, let fileURL else { throw RecorderError.notRecording }
        // This throws if the system already stopped the stream; the file is
        // still finalized in that case.
        try? await stream.stopCapture()
        try await waitForFile(timeout: 15)
        self.stream = nil
        self.recordingOutput = nil
        self.fileURL = nil
        return fileURL
    }

    private func waitForFile(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result = finishResult {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            finishContinuation = continuation
            lock.unlock()
            // Don't hang forever if the delegate never reports back.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolveFinish(.success(()))
            }
        }
    }

    private func resolveFinish(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation = finishContinuation {
            finishContinuation = nil
            finishResult = result
            lock.unlock()
            continuation.resume(with: result)
        } else {
            if finishResult == nil { finishResult = result }
            lock.unlock()
        }
    }

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolveFinish(.success(()))
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        resolveFinish(.failure(error))
        notifyUnexpectedStop(error)
    }

    // MARK: SCStreamDelegate / SCStreamOutput

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        notifyUnexpectedStop(error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    private func notifyUnexpectedStop(_ error: Error) {
        Task { @MainActor [weak self] in self?.onUnexpectedStop?(error) }
    }
}
