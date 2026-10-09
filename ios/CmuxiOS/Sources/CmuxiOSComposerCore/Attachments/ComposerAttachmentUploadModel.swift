import CmuxiOSFeatureKit
import Foundation

/// A file copied out of a system picker and ready for C4 to upload.
///
/// The picker owns the local copy. The upload model keeps the URL while the
/// transfer is active so a failed transfer can be retried without asking the
/// user to pick the file again.
public struct ComposerPickedAttachment: Hashable, Sendable, Identifiable {
    public let id: TransferID
    public let localURL: URL
    public let name: String
    public let mime: String
    public let byteCount: Int64

    public init(id: TransferID = TransferID(), localURL: URL, name: String, mime: String,
                byteCount: Int64) {
        self.id = id
        self.localURL = localURL
        self.name = name
        self.mime = mime
        self.byteCount = byteCount
    }
}

/// Client-side admission limits for one task composer draft.
///
/// C4 still enforces its own per-file cap on the Mac. These limits keep a
/// picker batch bounded before it starts any network work and leave room for a
/// clear error in the composer instead of a late `files.too_large` response.
public struct ComposerAttachmentUploadLimits: Hashable, Sendable {
    public static let `default` = Self()

    public var maximumCount: Int
    public var maximumBytesPerAttachment: Int64
    public var maximumTotalBytes: Int64

    public init(maximumCount: Int = 32, maximumBytesPerAttachment: Int64 = 1 << 30,
                maximumTotalBytes: Int64 = 2 << 30) {
        // Configuration can come from a host or a future remote policy. Clamp
        // malformed values instead of crashing the app while opening Compose.
        self.maximumCount = max(1, maximumCount)
        self.maximumBytesPerAttachment = max(0, maximumBytesPerAttachment)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }
}

/// Why a picked item was refused before an upload was started.
public enum ComposerAttachmentAdmissionError: Error, Hashable, Sendable {
    case duplicateID(TransferID)
    case emptyName
    case invalidByteCount
    case attachmentCountLimit(maximum: Int)
    case attachmentTooLarge(byteCount: Int64, maximum: Int64)
    case totalSizeLimit(total: Int64, maximum: Int64)
}

/// Owns the bounded upload state for the task composer.
///
/// This model intentionally has no UIKit dependency: PhotosUI and document
/// picker adapters can turn their copied URLs into ``ComposerPickedAttachment``
/// values, while the C4 implementation only has to satisfy
/// ``ComposerAttachmentUploading``. One item has one stable ``TransferID``
/// from admission through retry and into ``ComposerDraft``.
@MainActor
public final class ComposerAttachmentUploadModel {
    public private(set) var attachments: [ComposerAttachment] = []
    public var onChange: (() -> Void)?

    public let host: HostID
    public let limits: ComposerAttachmentUploadLimits

    private let uploader: any ComposerAttachmentUploading
    private var picked: [TransferID: ComposerPickedAttachment] = [:]
    private var jobs: [TransferID: Job] = [:]
    /// Set before creating a task. An eager task can otherwise finish a
    /// synchronous fake stream before `jobs` receives its handle.
    private var activeTokens: [TransferID: UUID] = [:]

    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }

    deinit {
        // The task body keeps the model weak, so this is a final safety net
        // for a composer dismissed without an explicit cancel-all action.
        for job in jobs.values { job.task.cancel() }
    }

    public init(host: HostID, uploader: any ComposerAttachmentUploading,
                limits: ComposerAttachmentUploadLimits = .default) {
        self.host = host
        self.uploader = uploader
        self.limits = limits
    }

    public var totalByteCount: Int64 {
        attachments.reduce(into: Int64(0)) { total, attachment in
            let (next, overflow) = total.addingReportingOverflow(max(0, attachment.byteCount))
            total = overflow ? .max : next
        }
    }

    public var hasPendingUploads: Bool {
        attachments.contains { $0.phase == .uploading }
    }

    /// Admits and starts one picker result. Validation happens before the
    /// placeholder is visible, so a refused item cannot consume a count slot.
    @discardableResult
    public func enqueue(_ item: ComposerPickedAttachment) throws -> TransferID {
        try validate(item)
        let attachment = ComposerAttachment(id: item.id, name: item.name, mime: item.mime,
                                            byteCount: item.byteCount)
        picked[item.id] = item
        attachments.append(attachment)
        changed()
        start(item.id)
        return item.id
    }

    /// Admits a picker batch atomically. If one item fails validation no item
    /// is added or uploaded; this keeps partial picker batches predictable.
    @discardableResult
    public func enqueue(_ items: [ComposerPickedAttachment]) throws -> [TransferID] {
        guard !items.isEmpty else { return [] }
        var seen = Set<TransferID>()
        var total = totalByteCount
        guard items.count <= limits.maximumCount - attachments.count else {
            throw ComposerAttachmentAdmissionError.attachmentCountLimit(maximum: limits.maximumCount)
        }
        for item in items {
            guard seen.insert(item.id).inserted, !picked.keys.contains(item.id) else {
                throw ComposerAttachmentAdmissionError.duplicateID(item.id)
            }
            try validate(item, currentTotal: total)
            total += item.byteCount
        }
        var ids: [TransferID] = []
        ids.reserveCapacity(items.count)
        for item in items {
            picked[item.id] = item
            attachments.append(ComposerAttachment(id: item.id, name: item.name, mime: item.mime,
                                                  byteCount: item.byteCount))
            ids.append(item.id)
        }
        changed()
        for id in ids { start(id) }
        return ids
    }

    /// Cancels and removes an item. A cancelled transfer never reappears when
    /// a late C4 progress value arrives.
    public func cancel(_ id: TransferID) {
        jobs.removeValue(forKey: id)?.task.cancel()
        activeTokens.removeValue(forKey: id)
        picked.removeValue(forKey: id)
        guard attachments.contains(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        changed()
    }

    /// Cancels every active upload. The picker owner calls this when the
    /// composer target or screen is discarded; individual rows can use
    /// ``cancel(_:)`` when the user removes one attachment.
    public func cancelAll() {
        for id in Array(jobs.keys) { cancel(id) }
    }

    /// Removes a non-running item without attempting to cancel an in-flight
    /// transfer. Call ``cancel(_:)`` for an active upload.
    public func remove(_ id: TransferID) {
        guard jobs[id] == nil else {
            cancel(id)
            return
        }
        picked.removeValue(forKey: id)
        guard attachments.contains(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        changed()
    }

    /// Restarts a failed upload with the same transfer and task attachment ID.
    /// Returns `false` for ready, uploading, cancelled or unknown IDs.
    @discardableResult
    public func retry(_ id: TransferID) -> Bool {
        guard let index = attachments.firstIndex(where: { $0.id == id }),
              attachments[index].phase == .failed, picked[id] != nil, jobs[id] == nil else { return false }
        attachments[index].phase = .uploading
        attachments[index].uploadID = nil
        changed()
        start(id)
        return true
    }

    // MARK: Private

    private func validate(_ item: ComposerPickedAttachment, currentTotal: Int64? = nil) throws {
        guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposerAttachmentAdmissionError.emptyName
        }
        guard item.byteCount >= 0 else { throw ComposerAttachmentAdmissionError.invalidByteCount }
        guard item.byteCount <= limits.maximumBytesPerAttachment else {
            throw ComposerAttachmentAdmissionError.attachmentTooLarge(
                byteCount: item.byteCount, maximum: limits.maximumBytesPerAttachment)
        }
        let total = currentTotal ?? totalByteCount
        let (candidateTotal, overflow) = total.addingReportingOverflow(item.byteCount)
        guard !overflow, candidateTotal <= limits.maximumTotalBytes else {
            throw ComposerAttachmentAdmissionError.totalSizeLimit(total: candidateTotal,
                                                                   maximum: limits.maximumTotalBytes)
        }
        guard !picked.keys.contains(item.id), !attachments.contains(where: { $0.id == item.id }) else {
            throw ComposerAttachmentAdmissionError.duplicateID(item.id)
        }
        guard attachments.count < limits.maximumCount else {
            throw ComposerAttachmentAdmissionError.attachmentCountLimit(maximum: limits.maximumCount)
        }
    }

    private func start(_ id: TransferID) {
        guard let item = picked[id], jobs[id] == nil else { return }
        let token = UUID()
        activeTokens[id] = token
        let uploader = self.uploader
        let host = self.host
        let task = Task { @MainActor [weak self] in
            // Let the handle install before a synchronous test uploader can
            // finish its stream and run the terminal cleanup path.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let stream = await uploader.upload(localURL: item.localURL, name: item.name, mime: item.mime, to: host)
            guard !Task.isCancelled else { return }
            var ended = false
            for await update in stream {
                guard !Task.isCancelled else { return }
                guard let self, self.activeTokens[id] == token, self.picked[id] != nil else { return }
                let normalized = self.normalized(update, for: item)
                self.apply(normalized, id: id, token: token)
                if normalized.phase == .ready || normalized.phase == .failed { ended = true }
                if ended { break }
            }
            guard !Task.isCancelled, let self, self.activeTokens[id] == token else { return }
            if !ended { self.fail(id, token: token) }
            self.activeTokens.removeValue(forKey: id)
            self.jobs.removeValue(forKey: id)
        }
        jobs[id] = Job(token: token, task: task)
    }

    private func normalized(_ update: ComposerAttachment, for item: ComposerPickedAttachment) -> ComposerAttachment {
        var normalized = update
        normalized.id = item.id
        normalized.name = item.name
        normalized.mime = item.mime
        normalized.byteCount = item.byteCount
        if normalized.phase == .ready {
            guard let upload = normalized.uploadID, Self.isValidUploadID(upload) else {
                normalized.phase = .failed
                normalized.uploadID = nil
                return normalized
            }
        } else if normalized.phase != .failed {
            normalized.uploadID = nil
            normalized.phase = .uploading
        }
        return normalized
    }

    private func apply(_ update: ComposerAttachment, id: TransferID, token: UUID) {
        guard activeTokens[id] == token, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        guard attachments[index].phase != .ready, attachments[index].phase != .failed else { return }
        attachments[index] = update
        changed()
    }

    private func fail(_ id: TransferID, token: UUID) {
        guard activeTokens[id] == token, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        guard attachments[index].phase != .ready else { return }
        attachments[index].phase = .failed
        attachments[index].uploadID = nil
        changed()
    }

    private func changed() { onChange?() }

    private static func isValidUploadID(_ id: String) -> Bool {
        guard id.hasPrefix("up_") else { return false }
        let suffix = id.dropFirst(3)
        return (2...64).contains(suffix.count) && suffix.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
    }
}
