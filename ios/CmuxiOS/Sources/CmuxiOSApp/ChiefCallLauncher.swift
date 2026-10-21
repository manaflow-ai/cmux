import AVFoundation
import CmuxChiefVoiceCore
import CmuxHomeCore
import CmuxiOSAuth
import CmuxiOSVoice
import Foundation
import UIKit

/// Routes Action Button / Siri / Shortcuts requests into the Chief call screen
/// (plans/cmux-next/ios-action-button-DESIGN.md).
///
/// A request that arrives before sign-in and Home are ready waits and runs
/// once Home shows. Each account gets its own coordinator and outbox folder, so
/// a note recorded as one account never posts as another. Interruptions of the
/// audio session end the running call.
@MainActor
final class ChiefCallLauncher {
    private let recorder: AudioSessionRecorder
    private let delivery: HomeChiefVoiceDelivery
    private let notesRoot: URL
    private var coordinator: ChiefCallCoordinator?
    private var account: String?
    private weak var presenter: UIViewController?
    private weak var screen: ChiefCallViewController?
    private var pending: ChiefVoiceRequest?
    private var interruptions: Task<Void, Never>?

    /// - Parameters:
    ///   - store: The signed-in account's Home store, read at delivery time.
    ///   - notesRoot: Parent folder of the per-account outboxes (Application Support/ChiefVoiceNotes).
    init(store: @escaping @MainActor () -> HomeStore?, notesRoot: URL) {
        recorder = AudioSessionRecorder(session: AVAudioSession.sharedInstance())
        delivery = HomeChiefVoiceDelivery(store: store)
        self.notesRoot = notesRoot
        let stream = recorder.interruptions()
        interruptions = Task { [weak self] in
            for await _ in stream { await self?.coordinator?.interrupted() }
        }
    }

    /// `Application Support/ChiefVoiceNotes`.
    static func defaultNotesRoot() -> URL {
        let support = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager().temporaryDirectory
        return support.appendingPathComponent("ChiefVoiceNotes", isDirectory: true)
    }

    /// An entry point asked for a call or a voice note.
    func handle(_ request: ChiefVoiceRequest) {
        guard let coordinator, let presenter else {
            pending = request
            return
        }
        if coordinator.state.isBusy {
            // A second press while recording hangs up (ignored while finishing).
            Task { await coordinator.handle(request) }
            return
        }
        present(request, coordinator: coordinator, on: presenter)
        Task { await coordinator.handle(request) }
    }

    /// Home is on screen for `account`: run a waiting request and retry saved notes.
    func homeReady(account: SignedInAccount, presenter: UIViewController) {
        self.presenter = presenter
        if self.account != account.userID {
            self.account = account.userID
            coordinator = makeCoordinator(for: account.userID)
        }
        guard let coordinator else { return }
        Task { await coordinator.drainOutbox() }
        if let request = pending {
            pending = nil
            handle(request)
        }
    }

    /// The user signed out: end a running call (its note stays in that account's outbox).
    func signedOut() {
        let running = coordinator
        coordinator = nil
        account = nil
        screen?.dismiss(animated: true)
        Task { await running?.end() }
    }

    private func makeCoordinator(for userID: String) -> ChiefCallCoordinator {
        let folder = String(userID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        return ChiefCallCoordinator(recorder: recorder, transcriber: OnDeviceSpeechTranscriber(locale: .current),
                                    microphone: MicrophonePermission(), delivery: delivery,
                                    outbox: VoiceNoteOutbox(directory: notesRoot.appendingPathComponent(folder, isDirectory: true)))
    }

    private func present(_ request: ChiefVoiceRequest, coordinator: ChiefCallCoordinator, on presenter: UIViewController) {
        screen?.dismiss(animated: false)
        let screen = ChiefCallViewController(coordinator: coordinator, chiefName: delivery.chiefName, mode: request)
        screen.onDone = { [weak screen] in screen?.dismiss(animated: true) }
        self.screen = screen
        var top = presenter
        while let next = top.presentedViewController { top = next }
        top.present(screen, animated: true)
    }
}
