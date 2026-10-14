#if os(iOS)
import AVFoundation
import Foundation
import Observation
import Speech

/// On-device dictation into the composer (SFSpeechRecognizer). Available only
/// when the app declares the microphone and speech usage strings; otherwise
/// the composer shows Send instead of the mic.
@MainActor
@Observable
final class Dictation {
    private(set) var isRunning = false
    /// The whole transcript of the current session.
    private(set) var transcript = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?

    static var isAvailable: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["NSMicrophoneUsageDescription"] != nil, info["NSSpeechRecognitionUsageDescription"] != nil else { return false }
        return SFSpeechRecognizer()?.isAvailable ?? false
    }

    func start(onText: @escaping @MainActor @Sendable (String) -> Void) {
        guard !isRunning else { return }
        Self.authorize { [weak self] ok in
            if ok { self?.begin(onText: onText) }
        }
    }

    nonisolated private static func authorize(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            let ok = status == .authorized
            Task { @MainActor in done(ok) }
        }
    }

    private func begin(onText: @escaping @MainActor @Sendable (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request))
        do { try engine.start() } catch { return }
        self.engine = engine
        transcript = ""
        isRunning = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, done in
            guard let self else { return }
            if let text { self.transcript = text; onText(text) }
            if done { self.stop() }
        })
    }

    // Built outside the main actor: the audio and speech callbacks run on
    // their own queues and must not inherit main-actor isolation.
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func handler(
        _ deliver: @escaping @MainActor @Sendable (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in deliver(text, done) }
        }
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
