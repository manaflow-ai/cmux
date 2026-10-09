import CmuxiOSFeatureKit
import Foundation

/// A weak, target-scoped receiver for C4's completed uploads. It neither
/// switches the user's target nor retains a dismissed composer session.
@MainActor
final class ComposerFileAttachmentSink: FileAttachmentSink {
    private weak var session: ComposerSession?
    private let target: ComposerTarget
    private let generation: UUID

    init(session: ComposerSession, target: ComposerTarget, generation: UUID) {
        self.session = session
        self.target = target
        self.generation = generation
    }

    func attach(_ attachment: FileAttachment) async {
        session?.accept(attachment, target: target, generation: generation)
    }
}
