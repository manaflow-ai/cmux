#if os(iOS)
public import CmuxChiefVoiceCore
import AVFoundation
import CmuxConversationCore
public import CnxChief
import Foundation
import Observation

/// Shows the Chief call screen and runs the call behind it.
///
/// The Action Button, Siri and Shortcuts intents call ``handle(_:)``: the
/// screen comes up and recording starts at once; a second press while
/// recording ends the call. The finished note is transcribed on the phone and
/// sent to the default Chief (``ChiefSources/primary``) as text; the Chief
/// session keeps it in its own outbox while the Chief is not connected.
@MainActor
@Observable
public final class ChiefVoiceController {
    /// The request the call screen shows; nil while the screen is closed.
    public private(set) var presented: ChiefVoiceRequest?
    /// The call flow the screen renders.
    public let coordinator: ChiefCallCoordinator
    /// The Chief's name for the screen title.
    public var chiefName: String? { sources.primary.title }

    @ObservationIgnored private let sources: ChiefSources
    @ObservationIgnored private var interruptions: Task<Void, Never>?

    /// Creates the controller.
    /// - Parameters:
    ///   - coordinator: The call flow.
    ///   - sources: Which Chief is the default, for the title.
    ///   - interruptions: Yields when another audio user takes the session; each ends the call.
    public init(coordinator: ChiefCallCoordinator, sources: ChiefSources, interruptions: AsyncStream<Void>) {
        self.coordinator = coordinator
        self.sources = sources
        self.interruptions = Task { [coordinator] in
            for await _ in interruptions { await coordinator.interrupted() }
        }
    }

    /// The app's controller: the phone's microphone, on-device speech, an
    /// outbox in Application Support, and delivery to the default Chief.
    /// - Parameter sources: The Chiefs Home shows.
    public static func live(sources: ChiefSources) -> ChiefVoiceController {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ChiefVoiceNotes", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChiefVoiceNotes", isDirectory: true)
        let recorder = AudioSessionRecorder(session: .sharedInstance())
        let delivery = ChiefVoiceTextDelivery(
            send: { text in sources.primary.send(ConversationComposeMessage(text: text)) },
            noTranscript: { seconds in VoiceText.noTranscript(seconds: Int(seconds.rounded())) }
        )
        let coordinator = ChiefCallCoordinator(
            recorder: recorder, transcriber: OnDeviceSpeechTranscriber(locale: .current),
            microphone: MicrophonePermission(), delivery: delivery,
            outbox: VoiceNoteOutbox(directory: directory)
        )
        return ChiefVoiceController(coordinator: coordinator, sources: sources, interruptions: recorder.interruptions())
    }

    /// Opens the call screen for `request` and starts, or ends, the call.
    /// - Parameter request: A call or a voice note.
    public func handle(_ request: ChiefVoiceRequest) async {
        if presented == nil { presented = request }
        await coordinator.handle(request)
    }

    /// Closes the screen; a running recording ends and is sent first.
    public func dismiss() {
        presented = nil
        guard case .recording = coordinator.state else { return }
        Task { await coordinator.end() }
    }

    /// Sends notes an earlier call left in the outbox.
    public func drainOutbox() async {
        await coordinator.drainOutbox()
    }
}
#endif
