@preconcurrency import AVFAudio
public import Foundation
@preconcurrency import Speech

/// Voice dictation into the prompt: Speech framework recognition, on-device
/// when the recognizer supports it (no audio leaves the phone), else Apple's
/// server recognition. Partial results stream to `onText`; `stop()` ends the
/// session (Send, a second tap, or leaving the screen). Shared with the
/// terminal composer (E4).
@MainActor
public final class DictationController {
    public enum Failure: Error {
        case denied
        case unavailable
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    public private(set) var isRunning = false
    /// The transcription so far (replaces the previous partial).
    public var onText: ((String) -> Void)?
    /// Recognition ended (final result, error or `stop()`).
    public var onEnd: (() -> Void)?

    /// Asks for speech and microphone permission, then starts listening.
    public init() {}

    public func start(locale: Locale = .current) async throws {
        guard !isRunning else { return }
        guard await Self.speechAuthorized(), await AVAudioApplication.requestRecordPermission() else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unavailable
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(appending: request))
        engine.prepare()
        try engine.start()
        self.request = request
        isRunning = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if let text { self.onText?(text) }
                if isFinal || failed { self.stop() }
            }
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onEnd?()
    }

    /// The tap runs on the audio thread; it only appends buffers to the request.
    private nonisolated static func tap(appending request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        @unknown default: return false
        }
    }
}
