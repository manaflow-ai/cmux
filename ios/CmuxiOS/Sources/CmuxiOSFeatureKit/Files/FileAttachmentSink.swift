/// Seam for lane C8: receives files uploaded for a task. The composer keeps
/// `TaskDraft.attachments` (transfer ids) and the paths from these values.
public protocol FileAttachmentSink: Sendable {
    func attach(_ attachment: FileAttachment) async
}
