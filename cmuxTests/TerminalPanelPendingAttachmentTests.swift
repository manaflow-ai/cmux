import AppKit
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class TextBoxAttachmentFocusBlocker: NSView {
    override var acceptsFirstResponder: Bool { true }

    var rejectsResignation = true

    override func resignFirstResponder() -> Bool {
        !rejectsResignation
    }
}

private actor NonCancellableTextBoxAttachmentPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TextBoxAttachmentPreparationCallRecorder {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private actor TextBoxAttachmentTargetRecorder {
    private(set) var targets: [TerminalImageTransferTarget] = []

    func record(_ target: TerminalImageTransferTarget) {
        targets.append(target)
    }
}

private final class ControlledTextBoxAttachmentRemoteUpload: @unchecked Sendable {
    private let lock = NSLock()
    private var completion:
        (@Sendable (Result<[String], Error>) -> Void)?
    private var cleanedPathsStorage: [[String]] = []

    var hasPendingCompletion: Bool {
        lock.withLock { completion != nil }
    }

    var cleanedPaths: [[String]] {
        lock.withLock { cleanedPathsStorage }
    }

    func install(
        _ completion: @escaping @Sendable (Result<[String], Error>) -> Void
    ) {
        lock.withLock {
            self.completion = completion
        }
    }

    func succeed(paths: [String]) {
        let completion = lock.withLock {
            let completion = self.completion
            self.completion = nil
            return completion
        }
        completion?(.success(paths))
    }

    func cleanup(paths: [String]) {
        lock.withLock {
            cleanedPathsStorage.append(paths)
        }
    }
}

@Suite("Terminal panel pending attachments", .serialized)
@MainActor
struct TerminalPanelPendingAttachmentTests {
    @Test
    func preparedImageAttachmentProvidesInlineThumbnailSource() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-prepared-thumbnail.png")
        let preparedFile = TextBoxPreparedFileAttachment(
            fileURL: fileURL,
            thumbnailPixelData: Data([0xff, 0x00, 0x00, 0xff]),
            thumbnailPixelWidth: 1,
            thumbnailPixelHeight: 1,
            thumbnailBytesPerRow: 4,
            localFileDisposition: .callerOwned
        )

        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: fileURL
            )
        )

        #expect(attachment.thumbnail != nil)
        #expect(attachment.inlineThumbnailSource != nil)
    }

    @Test
    func preparedCallerOwnedAttachmentPreservesTheUserFile() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-user-file-\(UUID().uuidString).txt")
        try Data("user-owned".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(fileURL: fileURL)
        let preparedFile = try #require(maybePreparedFile)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: fileURL)
        )

        #expect(preparedFile.localFileDisposition == .callerOwned)
        #expect(!attachment.cleanupLocalURLWhenDisposed)
        #expect(!attachment.requiresDurableCopyPreparationOnInsertion)
        await preparedFile.disposeOwnedLocalFileIfNeededOffMainActor()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.cleanupDisposableAttachmentFiles(
            [attachment],
            preservingActiveInlineAttachments: false
        )
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func preparedCmuxTemporaryAttachmentCarriesCleanupAndDurableCopyDisposition() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-owned-\(UUID().uuidString).png")
        try Data("owned-temporary".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        defer {
            let cleanupAttachment = TextBoxAttachment(
                localURL: temporaryURL,
                submissionText: TextBoxAttachment.submissionText(
                    forLocalFileURL: temporaryURL
                )
            )
            cleanupAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: temporaryURL
        )
        let preparedFile = try #require(maybePreparedFile)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL)
        )

        #expect(preparedFile.localFileDisposition == .cmuxTemporaryImage)
        #expect(attachment.cleanupLocalURLWhenDisposed)
        #expect(!attachment.requiresDurableCopyPreparationOnInsertion)

        TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()
        let persistedSnapshot = SessionTextBoxInputAttachmentSnapshot(attachment)
        let durablePath = try #require(persistedSnapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        #expect(
            persistedSnapshot.cleanupLocalPathWhenDisposed,
            "Session persistence should retain ownership of cmux's durable copy."
        )
        #expect(durableURL.path != temporaryURL.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: durableURL.path))

        await preparedFile.disposeOwnedLocalFileIfNeededOffMainActor()
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: durableURL.path))
    }

    @Test
    func preparedDraftCopyRemainsDisposableWithoutAnotherPreflight() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-draft-source-\(UUID().uuidString).png")
        try Data("owned-temporary".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let sourceAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: temporaryURL),
            cleanupLocalURLWhenDisposed: true
        )
        defer {
            sourceAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([temporaryURL])
        }
        let durableURL = try #require(
            sourceAttachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        )
        defer { try? FileManager.default.removeItem(at: durableURL) }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(fileURL: durableURL)
        let preparedFile = try #require(maybePreparedFile)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: durableURL)
        )

        #expect(preparedFile.localFileDisposition == .cmuxDraftCopy)
        #expect(attachment.cleanupLocalURLWhenDisposed)
        #expect(!attachment.requiresDurableCopyPreparationOnInsertion)

        await preparedFile.disposeOwnedLocalFileIfNeededOffMainActor()
        #expect(!FileManager.default.fileExists(atPath: durableURL.path))
        #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    @Test
    func remotePreparationDoesNotDeleteReplacementAtOwnedTemporaryPath() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-owned-swap-\(UUID().uuidString).txt")
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-owned-replacement-\(UUID().uuidString).txt")
        let originalData = Data("owned-original".utf8)
        let replacementData = Data("caller-replacement".utf8)
        try originalData.write(to: temporaryURL)
        try replacementData.write(to: replacementURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: replacementURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: temporaryURL,
            uploadTarget: .remote(.workspaceRemote),
            afterDescriptorValidation: {
                let renameResult = replacementURL.path.withCString {
                    replacementPath in
                    temporaryURL.path.withCString { temporaryPath in
                        Darwin.rename(replacementPath, temporaryPath)
                    }
                }
                precondition(renameResult == 0)
            }
        )
        let preparedFile = try #require(maybePreparedFile)
        let snapshotURL = preparedFile.fileURL

        #expect(preparedFile.localFileDisposition == .cmuxDraftCopy)
        #expect(try Data(contentsOf: snapshotURL) == originalData)
        #expect(try Data(contentsOf: temporaryURL) == replacementData)
        #expect(!GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(temporaryURL))

        await preparedFile.disposeOwnedLocalFileIfNeededOffMainActor()
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        GhosttyApp.terminalPasteboard.cleanupAllOwnedTemporaryImageFiles()
        #expect(try Data(contentsOf: temporaryURL) == replacementData)
    }

    @Test
    func remotePreparationRejectsSparseFileBeyondPerFileQuota() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-remote-snapshot-over-quota-\(UUID().uuidString).bin"
            )
        let descriptor = fileURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        try #require(descriptor >= 0)
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: fileURL)
        }
        try #require(Darwin.ftruncate(
            descriptor,
            TextBoxDraftAttachmentStorageQuotaLimits.maximumFileBytes + 1
        ) == 0)

        let preparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: fileURL,
            uploadTarget: .remote(.workspaceRemote)
        )

        #expect(preparedFile == nil)
    }

    @Test
    func remoteSnapshotQuotaCountsRetainedSparseLogicalSize() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-remote-snapshot-quota-seed-\(UUID().uuidString).txt"
            )
        try Data("seed".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(
            temporaryURL
        )
        let sourceAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        let durableURL = try #require(
            sourceAttachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        )
        let storageDirectory = durableURL.deletingLastPathComponent()
        let retainedURL = storageDirectory.appendingPathComponent(
            "aggregate-quota-\(UUID().uuidString).bin"
        )
        let uploadSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-remote-snapshot-quota-upload-\(UUID().uuidString).txt"
            )
        defer {
            try? FileManager.default.removeItem(at: retainedURL)
            try? FileManager.default.removeItem(at: uploadSourceURL)
            sourceAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }
        try Data("upload".utf8).write(to: uploadSourceURL)

        let descriptor = retainedURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        try #require(descriptor >= 0)
        let truncateResult = Darwin.ftruncate(
            descriptor,
            TextBoxDraftAttachmentStorageQuotaLimits.maximumAggregateBytes
        )
        Darwin.close(descriptor)
        try #require(truncateResult == 0)

        let preparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: uploadSourceURL,
            uploadTarget: .remote(.workspaceRemote)
        )
        #expect(preparedFile == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func durableStorageQuotaWaitHasABoundedDeadline() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-durable-quota-deadline-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let quota = TextBoxDraftAttachmentStorage.DurableStorageQuota()
        let firstDestination = storageDirectory.appendingPathComponent("first")
        let secondDestination = storageDirectory.appendingPathComponent("second")
        let firstReservation = try #require(quota.reserve(
            byteCount: 1,
            storageDirectory: storageDirectory,
            destinationURL: firstDestination,
            waitsForAccess: false
        ))

        let waiter = Task.detached {
            let clock = ContinuousClock()
            let startedAt = clock.now
            let reservation = quota.reserve(
                byteCount: 1,
                storageDirectory: storageDirectory,
                destinationURL: secondDestination,
                waitsForAccess: true
            )
            return (reservation, startedAt.duration(to: clock.now))
        }

        try await Task.sleep(for: .milliseconds(700))
        quota.release(firstReservation)
        let (secondReservation, elapsed) = await waiter.value
        if let secondReservation {
            quota.release(secondReservation)
        }

        #expect(secondReservation == nil)
        #expect(elapsed < .milliseconds(500))
    }

    @Test
    func localPreparationRelinquishesOwnershipAfterTemporaryPathReplacement() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-local-owned-swap-\(UUID().uuidString).txt")
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-local-replacement-\(UUID().uuidString).txt")
        let replacementData = Data("caller-replacement".utf8)
        try Data("owned-original".utf8).write(to: temporaryURL)
        try replacementData.write(to: replacementURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: replacementURL)
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: temporaryURL,
            afterDescriptorValidation: {
                let renameResult = replacementURL.path.withCString {
                    replacementPath in
                    temporaryURL.path.withCString { temporaryPath in
                        Darwin.rename(replacementPath, temporaryPath)
                    }
                }
                precondition(renameResult == 0)
            }
        )
        let preparedFile = try #require(maybePreparedFile)

        #expect(preparedFile.localFileDisposition == .callerOwned)
        #expect(!GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(temporaryURL))
        GhosttyApp.terminalPasteboard.cleanupAllOwnedTemporaryImageFiles()
        #expect(try Data(contentsOf: temporaryURL) == replacementData)
    }

    @Test
    func insertedTemporaryReplacementCleanupRemovesOnlyTheOwnedDraftSidecar() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-sidecar-source-\(UUID().uuidString).txt")
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-sidecar-replacement-\(UUID().uuidString).txt")
        let replacementData = Data("caller-replacement".utf8)
        try Data("owned-original".utf8).write(to: temporaryURL)
        try replacementData.write(to: replacementURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let cleanupAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: replacementURL)
            cleanupAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: temporaryURL
        )
        let preparedFile = try #require(maybePreparedFile)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()
        let persistedSnapshot = SessionTextBoxInputAttachmentSnapshot(attachment)
        let durablePath = try #require(persistedSnapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        #expect(durableURL != temporaryURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: durableURL.path))

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([attachment])
        let renameResult = replacementURL.path.withCString { replacementPath in
            temporaryURL.path.withCString { temporaryPath in
                Darwin.rename(replacementPath, temporaryPath)
            }
        }
        try #require(renameResult == 0)

        let replacementSnapshot = SessionTextBoxInputAttachmentSnapshot(
            attachment
        )
        #expect(!replacementSnapshot.cleanupLocalPathWhenDisposed)
        let restoredAttachment = replacementSnapshot.textBoxAttachment()
        #expect(!restoredAttachment.cleanupLocalURLWhenDisposed)
        #expect(restoredAttachment.localURL == temporaryURL.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: durableURL.path))

        textView.clearContent(cleanupAttachmentFiles: true)
        let restoredTextView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        restoredTextView.insertAttachments([restoredAttachment])
        restoredTextView.clearContent(cleanupAttachmentFiles: true)
        #expect(try Data(contentsOf: temporaryURL) == replacementData)
        #expect(!FileManager.default.fileExists(atPath: durableURL.path))
        #expect(!GhosttyApp.terminalPasteboard.isOwnedTemporaryImageFile(temporaryURL))
    }

    @Test
    func insertedPreparedDraftCopyDoesNotDeleteReplacementAfterItsIdentityChanges() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-draft-swap-source-\(UUID().uuidString).txt")
        try Data("owned-temporary".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let sourceAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            ),
            cleanupLocalURLWhenDisposed: true
        )
        let durableURL = try #require(
            sourceAttachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        )
        let replacementURL = durableURL.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: durableURL)
            try? FileManager.default.removeItem(at: replacementURL)
            sourceAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: durableURL
        )
        let preparedFile = try #require(maybePreparedFile)
        #expect(preparedFile.localFileDisposition == .cmuxDraftCopy)

        let replacementData = Data("caller-replacement".utf8)
        try replacementData.write(to: replacementURL)
        let renameResult = replacementURL.path.withCString { replacementPath in
            durableURL.path.withCString { durablePath in
                Darwin.rename(replacementPath, durablePath)
            }
        }
        try #require(renameResult == 0)

        #expect(preparedFile.localFileDisposition == .cmuxDraftCopy)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: durableURL
            )
        )
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([attachment])
        #expect(textView.inlineAttachments().count == 1)

        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(try Data(contentsOf: durableURL) == replacementData)
    }

    @Test
    func restoredDraftCopyDoesNotDeleteAReplacementAfterSnapshot() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-restored-draft-source-\(UUID().uuidString).txt")
        try Data("owned-temporary".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(temporaryURL)
        let cleanupAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        defer {
            cleanupAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(
            fileURL: temporaryURL
        )
        let preparedFile = try #require(maybePreparedFile)
        let attachment = TextBoxAttachment(
            preparedFile: preparedFile,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()
        let snapshot = SessionTextBoxInputAttachmentSnapshot(attachment)
        let durablePath = try #require(snapshot.localPath)
        let durableURL = URL(fileURLWithPath: durablePath).standardizedFileURL
        let replacementURL = durableURL.deletingLastPathComponent()
            .appendingPathComponent("replacement-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: durableURL)
            try? FileManager.default.removeItem(at: replacementURL)
        }

        #expect(snapshot.cleanupLocalPathWhenDisposed)
        #expect(snapshot.cleanupPathEntryIdentity != nil)
        let restoredAttachment = snapshot.textBoxAttachment()
        #expect(restoredAttachment.cleanupLocalURLWhenDisposed)
        let replacementData = Data("caller-replacement".utf8)
        try replacementData.write(to: replacementURL)
        let renameResult = replacementURL.path.withCString { replacementPath in
            durableURL.path.withCString { durablePath in
                Darwin.rename(replacementPath, durablePath)
            }
        }
        try #require(renameResult == 0)

        let restoredTextView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        restoredTextView.insertAttachments([restoredAttachment])
        restoredTextView.clearContent(cleanupAttachmentFiles: true)
        #expect(try Data(contentsOf: durableURL) == replacementData)
    }

    @Test
    func legacyOwnedDraftSnapshotRecoversCleanupIdentity() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-legacy-draft-source-\(UUID().uuidString).txt"
            )
        try Data("legacy-owned".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(
            temporaryURL
        )
        let sourceAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        let durableURL = try #require(
            sourceAttachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        )
        defer {
            try? FileManager.default.removeItem(at: durableURL)
            sourceAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let legacySnapshot = SessionTextBoxInputAttachmentSnapshot(
            displayName: durableURL.lastPathComponent,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: durableURL
            ),
            submissionPath: durableURL.path,
            localPath: durableURL.path,
            cleanupLocalPathWhenDisposed: true,
            cleanupPathEntryIdentity: nil
        )
        let restoredAttachment = legacySnapshot.textBoxAttachment()
        #expect(restoredAttachment.cleanupLocalURLWhenDisposed)
        #expect(restoredAttachment.cleanupPathEntryIdentity != nil)

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([restoredAttachment])
        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(!FileManager.default.fileExists(atPath: durableURL.path))
    }

    @Test
    func legacyRemoteSnapshotRecoversCleanupIdentity() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-legacy-remote-source-\(UUID().uuidString).txt"
            )
        try Data("legacy-remote".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let preparedFile = try #require(
            await TextBoxPreparedFileAttachment.prepare(
                fileURL: sourceURL,
                uploadTarget: .remote(.workspaceRemote)
            )
        )
        let snapshotURL = preparedFile.fileURL
        defer {
            TextBoxAttachment.disposePreparedLocalFileIfNeeded(preparedFile)
        }
        let legacySnapshot = SessionTextBoxInputAttachmentSnapshot(
            displayName: preparedFile.displayName,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: snapshotURL
            ),
            submissionPath: snapshotURL.path,
            localPath: snapshotURL.path,
            cleanupLocalPathWhenDisposed: true,
            cleanupPathEntryIdentity: nil
        )
        let restoredAttachment = legacySnapshot.textBoxAttachment()
        #expect(restoredAttachment.cleanupLocalURLWhenDisposed)
        #expect(restoredAttachment.cleanupPathEntryIdentity != nil)

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([restoredAttachment])
        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test
    func legacyCleanupFlagDoesNotClaimUnknownPath() throws {
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-legacy-caller-file-\(UUID().uuidString).txt"
            )
        let contents = Data("caller-owned".utf8)
        try contents.write(to: externalURL)
        defer { try? FileManager.default.removeItem(at: externalURL) }

        let legacySnapshot = SessionTextBoxInputAttachmentSnapshot(
            displayName: externalURL.lastPathComponent,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: externalURL
            ),
            submissionPath: externalURL.path,
            localPath: externalURL.path,
            cleanupLocalPathWhenDisposed: true,
            cleanupPathEntryIdentity: nil
        )
        let restoredAttachment = legacySnapshot.textBoxAttachment()
        #expect(!restoredAttachment.cleanupLocalURLWhenDisposed)
        #expect(restoredAttachment.cleanupPathEntryIdentity == nil)

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([restoredAttachment])
        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(try Data(contentsOf: externalURL) == contents)
    }

    @Test
    func legacyCleanupMigrationRejectsSymlinkInOwnedLayout() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-legacy-symlink-seed-\(UUID().uuidString).txt"
            )
        try Data("seed".utf8).write(to: temporaryURL)
        GhosttyApp.terminalPasteboard.debugRegisterOwnedTemporaryImageFile(
            temporaryURL
        )
        let sourceAttachment = TextBoxAttachment(
            localURL: temporaryURL,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: temporaryURL
            )
        )
        let durableURL = try #require(
            sourceAttachment.debugPrepareSessionDraftCopySynchronouslyForTesting()
        )
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-legacy-symlink-target-\(UUID().uuidString).txt"
            )
        let contents = Data("caller-owned".utf8)
        try contents.write(to: externalURL)
        let symlinkURL = durableURL.deletingLastPathComponent()
            .appendingPathComponent("deadbeef-link.txt")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: externalURL
        )
        defer {
            try? FileManager.default.removeItem(at: symlinkURL)
            try? FileManager.default.removeItem(at: externalURL)
            sourceAttachment.debugCancelSessionDraftCopyForTesting()
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles([
                temporaryURL
            ])
        }

        let legacySnapshot = SessionTextBoxInputAttachmentSnapshot(
            displayName: symlinkURL.lastPathComponent,
            submissionText: TextBoxAttachment.submissionText(
                forLocalFileURL: symlinkURL
            ),
            submissionPath: symlinkURL.path,
            localPath: symlinkURL.path,
            cleanupLocalPathWhenDisposed: true,
            cleanupPathEntryIdentity: nil
        )
        let restoredAttachment = legacySnapshot.textBoxAttachment()
        #expect(!restoredAttachment.cleanupLocalURLWhenDisposed)
        #expect(restoredAttachment.cleanupPathEntryIdentity == nil)

        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        textView.insertAttachments([restoredAttachment])
        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(try Data(contentsOf: externalURL) == contents)
        #expect(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    @Test
    func autosaveFingerprintIncludesAttachmentCleanupIdentity() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
        let firstIdentityURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fingerprint-identity-\(UUID().uuidString)-1")
        let secondIdentityURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-fingerprint-identity-\(UUID().uuidString)-2")
        try Data("first".utf8).write(to: firstIdentityURL)
        try Data("second".utf8).write(to: secondIdentityURL)
        defer {
            try? FileManager.default.removeItem(at: firstIdentityURL)
            try? FileManager.default.removeItem(at: secondIdentityURL)
        }
        let firstIdentity = try #require(
            TextBoxPreparedLocalFileIdentity.capture(at: firstIdentityURL)
        )
        let secondIdentity = try #require(
            TextBoxPreparedLocalFileIdentity.capture(at: secondIdentityURL)
        )
        #expect(firstIdentity != secondIdentity)

        let firstAttachment = SessionTextBoxInputAttachmentSnapshot(
            displayName: "moon.png",
            submissionText: "/tmp/moon.png",
            submissionPath: "/tmp/moon.png",
            localPath: "/tmp/moon.png",
            cleanupLocalPathWhenDisposed: true,
            cleanupPathEntryIdentity: firstIdentity
        )
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.attachment(firstAttachment)]
        ))
        let firstFingerprint = manager.sessionAutosaveFingerprint()

        let secondAttachment = SessionTextBoxInputAttachmentSnapshot(
            displayName: firstAttachment.displayName,
            submissionText: firstAttachment.submissionText,
            submissionPath: firstAttachment.submissionPath,
            localPath: firstAttachment.localPath,
            cleanupLocalPathWhenDisposed:
                firstAttachment.cleanupLocalPathWhenDisposed,
            cleanupPathEntryIdentity: secondIdentity
        )
        terminalPanel.restoreSessionTextBoxDraft(SessionTextBoxInputDraftSnapshot(
            isActive: true,
            parts: [.attachment(secondAttachment)]
        ))

        #expect(firstFingerprint != manager.sessionAutosaveFingerprint())
    }

    @Test
    func pendingAttachmentsAreCoalescedAndBoundedUntilTheViewMounts() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachments-\(UUID().uuidString)", isDirectory: true)
        let queuedURLs = (0..<(TerminalPanel.maximumPendingTextBoxAttachmentCount - 1)).map {
            directoryURL.appendingPathComponent("file-\($0).txt")
        }
        let firstURL = try #require(queuedURLs.first)

        #expect(panel.attachFilesToTextBoxInput([firstURL, firstURL]) == .queued)
        #expect(panel.attachFilesToTextBoxInput([firstURL]) == .queued)
        #expect(panel.attachFilesToTextBoxInput(Array(queuedURLs.dropFirst())) == .queued)

        let rejectedURLs = [
            directoryURL.appendingPathComponent("rejected-1.txt"),
            directoryURL.appendingPathComponent("rejected-2.txt"),
        ]
        #expect(panel.attachFilesToTextBoxInput(rejectedURLs) == .queueFull)

        let view = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return true
        }
        panel.registerTextBoxInputView(view)
        #expect(insertionCalls.isEmpty)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)

        #expect(insertionCalls.count == 1)
        let insertedURLs = try #require(insertionCalls.first)
        #expect(insertedURLs == queuedURLs.map(\.standardizedFileURL))
        #expect(Set(insertedURLs).isDisjoint(with: rejectedURLs.map(\.standardizedFileURL)))
    }

    @Test
    func failedViewInsertionKeepsTheBoundedBatchForRetry() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachment-retry-\(UUID().uuidString).txt")
        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)

        let view = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return insertionCalls.count > 1
        }
        panel.registerTextBoxInputView(view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)
        panel.textBoxInputViewDidMoveToWindow(view)
        panel.textBoxInputViewDidMoveToWindow(view)

        let standardizedURL = fileURL.standardizedFileURL
        #expect(insertionCalls == [[standardizedURL], [standardizedURL]])
    }

    @Test
    func preparedDuplicateOfHiddenRawAttachmentRunsIndependently() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachment-coalesced-\(UUID().uuidString).txt")
        let callRecorder = TextBoxAttachmentPreparationCallRecorder()
        let (finishedStream, finishedContinuation) =
            AsyncStream<Bool>.makeStream()
        defer { finishedContinuation.finish() }
        var completionValues: [Bool] = []

        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                await callRecorder.recordCall()
                return nil
            },
            target: .local,
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        #expect(await callRecorder.callCount == 1)
        #expect(completionValues == [false])

        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return true
        }
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)

        #expect(insertionCalls == [[fileURL.standardizedFileURL]])
        #expect(completionValues == [false])
    }

    @Test(.timeLimit(.minutes(1)))
    func rawRequestDoesNotDisappearBehindPreparingRequestForSamePath() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let preparationGate = NonCancellableTextBoxAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        defer {
            Task { await preparationGate.release() }
            startedContinuation.finish()
            finishedContinuation.finish()
            panel.close()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-raw-after-prepared-same-path-\(UUID().uuidString).txt"
            )
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                startedContinuation.yield()
                await preparationGate.wait()
                return nil
            },
            target: .local,
            budget: budget,
            completion: { finishedContinuation.yield($0) }
        ) == .queued)

        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)

        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return true
        }
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)

        #expect(insertionCalls == [[fileURL.standardizedFileURL]])

        panel.close()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        await preparationGate.release()
        #expect(
            await waitForIdleAttachmentPreparationBudget(budget)
                == .init(
                    globalConcurrentCount: 0,
                    globalReservedBytes: 0,
                    queuedCount: 0
                )
        )
    }

    @Test
    func failedRawInsertionDoesNotRepeatIndependentPreparedCompletion() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pending-attachment-failed-\(UUID().uuidString).txt")
        let (finishedStream, finishedContinuation) =
            AsyncStream<Bool>.makeStream()
        defer { finishedContinuation.finish() }
        var completionValues: [Bool] = []

        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .queued)
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in nil },
            target: .local,
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)

        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        var insertionCalls: [[URL]] = []
        view.onInsertFileURLs = { urls, _ in
            insertionCalls.append(urls)
            return insertionCalls.count > 1
        }
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.close() }

        panel.textBoxInputViewDidMoveToWindow(view)
        #expect(completionValues == [false])

        panel.textBoxInputViewDidMoveToWindow(view)

        let standardizedURL = fileURL.standardizedFileURL
        #expect(insertionCalls == [[standardizedURL], [standardizedURL]])
        #expect(completionValues == [false])
    }

    @Test(.timeLimit(.minutes(1)))
    func independentPreparedRequestCountsTowardTheBoundAndFailsOnClose() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let preparationGate = NonCancellableTextBoxAttachmentPreparationGate()
        let (startedStream, startedContinuation) =
            AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) =
            AsyncStream<Bool>.makeStream()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-pending-attachment-callback-bound-\(UUID().uuidString)",
                isDirectory: true
            )
        let queuedURLs = (0..<(TerminalPanel.maximumPendingTextBoxAttachmentCount - 1)).map {
            directoryURL.appendingPathComponent("file-\($0).txt")
        }
        var completionValues: [Bool] = []
        defer {
            Task { await preparationGate.release() }
            startedContinuation.finish()
            finishedContinuation.finish()
            panel.close()
        }

        #expect(panel.attachFilesToTextBoxInput(queuedURLs) == .queued)
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            queuedURLs[0],
            using: { _, _ in
                startedContinuation.yield()
                await preparationGate.wait()
                return nil
            },
            target: .local,
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)
        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        #expect(panel.attachFilesToTextBoxInput([
            directoryURL.appendingPathComponent("over-limit.txt")
        ]) == .queueFull)
        #expect(completionValues.isEmpty)

        panel.close()

        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        #expect(completionValues == [false])
        await preparationGate.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func samePathWithDifferentFrozenRoutesDoesNotCoalesce() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let firstPreparationGate = NonCancellableTextBoxAttachmentPreparationGate()
        let targetRecorder = TextBoxAttachmentTargetRecorder()
        let (firstStartedStream, firstStartedContinuation) =
            AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) =
            AsyncStream<Bool>.makeStream()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 2,
            perComposerConcurrentCount: 2,
            globalReservedBytes: 64 * 1024 * 1024,
            perComposerReservedBytes: 64 * 1024 * 1024,
            maximumQueuedCount: 2
        ))
        defer {
            Task { await firstPreparationGate.release() }
            firstStartedContinuation.finish()
            finishedContinuation.finish()
            panel.close()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-same-path-different-routes-\(UUID().uuidString).txt"
            )
        let remoteSession = DetectedSSHSession(
            destination: "other@example.com",
            port: 2200,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, target in
                await targetRecorder.record(target)
                firstStartedContinuation.yield()
                await firstPreparationGate.wait()
                return nil
            },
            target: .local,
            budget: budget,
            completion: { finishedContinuation.yield($0) }
        ) == .queued)

        var firstStartedIterator = firstStartedStream.makeAsyncIterator()
        try #require(await firstStartedIterator.next() != nil)
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, target in
                await targetRecorder.record(target)
                return nil
            },
            target: .remote(.detectedSSH(remoteSession)),
            budget: budget,
            completion: { finishedContinuation.yield($0) }
        ) == .queued)

        await firstPreparationGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        #expect(await finishedIterator.next() == false)
        let targets = await targetRecorder.targets
        #expect(targets.count == 2)
        #expect(targets.contains(.local))
        #expect(targets.contains(.remote(.detectedSSH(remoteSession))))
        #expect(
            await waitForIdleAttachmentPreparationBudget(budget)
                == .init(
                    globalConcurrentCount: 0,
                    globalReservedBytes: 0,
                    queuedCount: 0
                )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineRetainsBudgetUntilCancellationIgnoringPreparerReturns() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let preparationGate = NonCancellableTextBoxAttachmentPreparationGate()
        let followerCallRecorder = TextBoxAttachmentPreparationCallRecorder()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (returnedStream, returnedContinuation) = AsyncStream<Void>.makeStream()
        let (deadlineStream, deadlineContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        defer {
            Task { await preparationGate.release() }
            startedContinuation.finish()
            returnedContinuation.finish()
            deadlineContinuation.finish()
            finishedContinuation.finish()
            panel.close()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-hung-prepared-deadline-\(UUID().uuidString).txt"
            )
        var completionValues: [Bool] = []
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                startedContinuation.yield()
                await preparationGate.wait()
                returnedContinuation.yield()
                return nil
            },
            target: .local,
            budget: budget,
            deadlineWaiter: {
                for await _ in deadlineStream {
                    return
                }
                throw CancellationError()
            },
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)

        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        #expect(await budget.snapshot() == .init(
            globalConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            queuedCount: 0
        ))

        deadlineContinuation.yield()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        #expect(await budget.snapshot() == .init(
            globalConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            queuedCount: 0
        ))
        #expect(completionValues == [false])

        let followerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-hung-prepared-follower-\(UUID().uuidString).txt"
            )
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            followerURL,
            using: { _, _ in
                await followerCallRecorder.recordCall()
                return nil
            },
            target: .local,
            budget: budget,
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)
        var queuedSnapshot = await budget.snapshot()
        for _ in 0..<20_000 {
            guard queuedSnapshot.queuedCount == 0 else { break }
            await Task.yield()
            queuedSnapshot = await budget.snapshot()
        }
        #expect(queuedSnapshot == .init(
            globalConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            queuedCount: 1
        ))
        #expect(await followerCallRecorder.callCount == 0)

        await preparationGate.release()
        var returnedIterator = returnedStream.makeAsyncIterator()
        try #require(await returnedIterator.next() != nil)
        #expect(await finishedIterator.next() == false)
        #expect(
            await waitForIdleAttachmentPreparationBudget(budget)
                == .init(
                    globalConcurrentCount: 0,
                    globalReservedBytes: 0,
                    queuedCount: 0
                )
        )
        #expect(await followerCallRecorder.callCount == 1)
        #expect(completionValues == [false, false])
    }

    @Test
    func workspaceRemoteWithoutCapturedControllerFailsClosedBeforePreparation() async {
        let panel = TerminalPanel(workspaceId: UUID())
        let callRecorder = TextBoxAttachmentPreparationCallRecorder()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        defer { panel.close() }

        var completionValues: [Bool] = []
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-workspace-remote-without-controller-\(UUID().uuidString).txt"
            )
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                await callRecorder.recordCall()
                return nil
            },
            target: .remote(.workspaceRemote),
            budget: budget,
            completion: { completionValues.append($0) }
        ) == .queued)

        #expect(completionValues == [false])
        #expect(await callRecorder.callCount == 0)
        #expect(await budget.snapshot() == .init(
            globalConcurrentCount: 0,
            globalReservedBytes: 0,
            queuedCount: 0
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func abandonedSuccessfulRemoteUploadIsCleanedAfterDeadline() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let uploader = ControlledTextBoxAttachmentRemoteUpload()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-abandoned-upload-deadline-\(UUID().uuidString).txt"
            )
        let preparedFile = TextBoxPreparedFileAttachment(
            fileURL: fileURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        panel.textBoxInputViewDidMoveToWindow(view)
        let (deadlineStream, deadlineContinuation) =
            AsyncStream<Void>.makeStream()
        defer {
            deadlineContinuation.finish()
            window.close()
            panel.close()
        }

        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in preparedFile },
            target: .remote(.workspaceRemote),
            remoteUploader: { _, _, completion in
                uploader.install(completion)
            },
            remoteCleanup: { uploader.cleanup(paths: $0) },
            deadlineWaiter: {
                for await _ in deadlineStream {
                    return
                }
                throw CancellationError()
            },
            completion: { _ in }
        ) == .queued)
        #expect(await waitUntil { uploader.hasPendingCompletion })

        window.contentView = NSView(frame: view.bounds)
        uploader.succeed(paths: ["/tmp/cmux-drop-abandoned"])
        for _ in 0..<100 {
            await Task.yield()
        }
        deadlineContinuation.yield()

        #expect(await waitUntil {
            uploader.cleanedPaths == [["/tmp/cmux-drop-abandoned"]]
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulRemoteUploadCompletingAfterPanelCloseIsCleaned() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let uploader = ControlledTextBoxAttachmentRemoteUpload()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-abandoned-upload-close-\(UUID().uuidString).txt"
            )
        let preparedFile = TextBoxPreparedFileAttachment(
            fileURL: fileURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        panel.textBoxInputViewDidMoveToWindow(view)
        defer { window.close() }

        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in preparedFile },
            target: .remote(.workspaceRemote),
            remoteUploader: { _, _, completion in
                uploader.install(completion)
            },
            remoteCleanup: { uploader.cleanup(paths: $0) },
            completion: { _ in }
        ) == .queued)
        #expect(await waitUntil { uploader.hasPendingCompletion })

        panel.close()
        uploader.succeed(paths: ["/tmp/cmux-drop-late"])

        #expect(await waitUntil {
            uploader.cleanedPaths == [["/tmp/cmux-drop-late"]]
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func unexpectedExtraRemoteUploadPathsAreRejectedAndCleaned() async throws {
        let panel = TerminalPanel(workspaceId: UUID())
        let uploader = ControlledTextBoxAttachmentRemoteUpload()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-extra-upload-paths-\(UUID().uuidString).txt"
            )
        let preparedFile = TextBoxPreparedFileAttachment(
            fileURL: fileURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        panel.textBoxInputViewDidMoveToWindow(view)
        defer {
            window.close()
            panel.close()
        }

        var completionValues: [Bool] = []
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in preparedFile },
            target: .remote(.workspaceRemote),
            remoteUploader: { _, _, completion in
                uploader.install(completion)
            },
            remoteCleanup: { uploader.cleanup(paths: $0) },
            completion: { completionValues.append($0) }
        ) == .queued)
        #expect(await waitUntil { uploader.hasPendingCompletion })

        let paths = ["/tmp/cmux-drop-first", "/tmp/cmux-drop-extra"]
        uploader.succeed(paths: paths)

        #expect(await waitUntil {
            uploader.cleanedPaths == [paths] && completionValues == [false]
        })
        #expect(view.inlineAttachments().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func typedTextBesidePreparedMarkerSurvivesReplacementUndoAndRedo() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        view.allowsUndo = true
        view.string = "left "
        view.setSelectedRange(NSRange(location: 5, length: 0))
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        _ = window.makeFirstResponder(view)
        panel.textBoxInputViewDidMoveToWindow(view)

        let preparationGate = NonCancellableTextBoxAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            Task { await preparationGate.release() }
            startedContinuation.finish()
            finishedContinuation.finish()
            window.close()
            panel.close()
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-prepared-marker-typing-\(UUID().uuidString).txt"
            )
        let preparedFile = TextBoxPreparedFileAttachment(
            fileURL: fileURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                startedContinuation.yield()
                await preparationGate.wait()
                return preparedFile
            },
            target: .local,
            completion: { finishedContinuation.yield($0) }
        ) == .queued)

        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        let markerID = try #require(
            view.pendingAttachmentUploadPlaceholderIDs().first
        )
        #expect(
            Set(view.typingAttributes.keys)
                == Set(view.currentTextAttributes().keys)
        )
        view.undoManager?.removeAllActions()

        let markerRange = (view.attributedString().string as NSString)
            .range(of: "\u{200B}")
        try #require(markerRange.location != NSNotFound)
        let markerLocation = markerRange.location
        view.typingAttributes = view.attributedString().attributes(
            at: markerLocation,
            effectiveRange: nil
        )
        view.setSelectedRange(NSRange(
            location: markerLocation + 1,
            length: 0
        ))
        view.insertText(" tail", replacementRange: view.selectedRange())
        view.breakUndoCoalescing()

        #expect(view.plainText() == "left  tail")
        #expect(
            view.pendingAttachmentUploadPlaceholderIDs() == Set([markerID])
        )

        await preparationGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        let expectedSubmission =
            "left \(TextBoxAttachment.submissionText(forPath: fileURL.path)) tail"
        #expect(view.submissionText() == expectedSubmission)
        #expect(view.inlineAttachments().count == 1)

        let undoManager = try #require(view.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        #expect(
            view.submissionText()
                == "left \(TextBoxAttachment.submissionText(forPath: fileURL.path))"
        )
        #expect(view.inlineAttachments().count == 1)

        #expect(undoManager.canRedo)
        undoManager.redo()
        #expect(view.submissionText() == expectedSubmission)
        #expect(view.inlineAttachments().count == 1)
        #expect(!view.hasPendingAttachmentUploadPlaceholder())
    }

    @Test
    func duplicateAndUndoRestoredPreparedMarkersAreSwept() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let panel = try #require(workspace.focusedTerminalPanel)
        let view = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        view.allowsUndo = true
        view.string = "ready"
        view.setSelectedRange(NSRange(location: 5, length: 0))
        panel.registerTextBoxInputView(view)
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        _ = window.makeFirstResponder(view)
        defer { window.close() }
        panel.textBoxInputViewDidMoveToWindow(view)

        let (preparationStream, preparationContinuation) =
            AsyncStream<Void>.makeStream()
        let (deadlineStream, deadlineContinuation) =
            AsyncStream<Void>.makeStream()
        defer {
            preparationContinuation.finish()
            deadlineContinuation.finish()
        }
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-prepared-marker-\(UUID().uuidString).txt")
        var completionValues: [Bool] = []
        #expect(panel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { _, _ in
                for await _ in preparationStream {}
                return nil
            },
            target: .local,
            budget: budget,
            deadlineWaiter: {
                for await _ in deadlineStream {}
                throw CancellationError()
            },
            completion: { completionValues.append($0) }
        ) == .queued)

        let requestID = try #require(
            view.pendingAttachmentUploadPlaceholderIDs().first
        )
        let singleMarkerLength = view.attributedString().length
        #expect(singleMarkerLength == 6)

        view.insertPendingAttachmentUploadPlaceholder(id: requestID)

        #expect(
            view.pendingAttachmentUploadPlaceholderIDs() == Set([requestID])
        )
        #expect(view.attributedString().length == singleMarkerLength)
        #expect(completionValues.isEmpty)

        view.undoManager?.removeAllActions()
        view.insertText(
            "",
            replacementRange: NSRange(location: 5, length: 1)
        )

        #expect(completionValues == [false])
        #expect(!view.hasPendingAttachmentUploadPlaceholder())
        #expect(view.attributedString().length == 5)

        let undoEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        ))
        #expect(view.performKeyEquivalent(with: undoEvent))
        #expect(!view.hasPendingAttachmentUploadPlaceholder())
        #expect(view.attributedString().length == 5)

        var submitCount = 0
        view.onSubmit = { submitCount += 1 }
        view.submitIfAllowed()
        #expect(submitCount == 1)
    }

    @Test
    func mountedFocusRejectionDoesNotRetryAfterTheViewMoves() {
        let panel = TerminalPanel(workspaceId: UUID())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-mounted-focus-rejection-\(UUID().uuidString).txt")
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        var insertedURLs: [URL] = []
        textView.onInsertFileURLs = { urls, _ in
            insertedURLs = urls
            return true
        }

        let blocker = TextBoxAttachmentFocusBlocker(frame: .zero)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        contentView.addSubview(textView)
        contentView.addSubview(blocker)
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        panel.registerTextBoxInputView(textView)
        defer {
            blocker.rejectsResignation = false
            _ = window.makeFirstResponder(nil)
            window.close()
            panel.surface.teardownSurface()
        }

        #expect(window.makeFirstResponder(blocker))
        #expect(panel.attachFilesToTextBoxInput([fileURL]) == .completed)
        #expect(window.firstResponder === blocker)
        #expect(insertedURLs == [fileURL.standardizedFileURL])
#if DEBUG
        #expect(!panel.debugHasPendingTextBoxFocusRequest)
#endif

        blocker.rejectsResignation = false
        panel.textBoxInputViewDidMoveToWindow(textView)

        #expect(window.firstResponder === blocker)
    }

    private func waitForIdleAttachmentPreparationBudget(
        _ budget: TextBoxAttachmentPreparationBudget
    ) async -> TextBoxAttachmentPreparationBudget.Snapshot {
        var snapshot = await budget.snapshot()
        for _ in 0..<20_000 {
            if snapshot.globalConcurrentCount == 0,
               snapshot.globalReservedBytes == 0,
               snapshot.queuedCount == 0 {
                return snapshot
            }
            await Task.yield()
            snapshot = await budget.snapshot()
        }
        return snapshot
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<20_000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
