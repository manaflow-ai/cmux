public import CmuxiOSFeatureKit
import Foundation

/// What the composer asks of lane C4: stage and upload a picked file to a
/// Mac for a task. C4's `FileSendActions.pick(for: .composer)` and its
/// `FileAttachmentSink` fill this; until C4 merges, attaching is unavailable
/// and the UI hides the attach button.
public protocol ComposerAttachmentUploading: Sendable {
    /// Uploads a local file (already copied out of the picker) to `host`;
    /// yields the attachment as it progresses, last with `.ready` (and its
    /// upload id) or `.failed`. Implementations must observe cancellation:
    /// return promptly when the calling task is cancelled and finish the
    /// stream so an upload row cannot retain a suspended iterator.
    func upload(localURL: URL, name: String, mime: String, to host: HostID) async -> AsyncStream<ComposerAttachment>
}
