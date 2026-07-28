import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import CmuxUpdater
import Darwin
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette typed view and identifier outcomes", .serialized)
struct CommandPaletteTypedViewAndIdentifierOutcomeTests {
    @Test func triggerFlashIsVisibleOnlyWithACapturedPanel() throws {
        let contribution = try #require(
            ContentView.commandPaletteViewCommandContributions().first {
                $0.commandId == "palette.triggerFlash"
            }
        )
        var context = CommandPaletteContextSnapshot()

        #expect(!contribution.when(context))
        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(contribution.when(context))
    }

    @Test func identifierCopyHandlersWriteTheExactBackgroundTargetAndReportCompletion() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("cmux.palette.identifiers.\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerIdentifierCopyCommandHandlers(
            &registry,
            context: fixture.context,
            pasteboard: pasteboard
        )
        let paneID = try #require(
            fixture.targetWorkspace.paneId(forPanelId: fixture.targetPanelID)?.id
        )
        let panel = try #require(fixture.targetWorkspace.panels[fixture.targetPanelID])
        let expectedSubstringByCommandID = [
            "palette.copyWorkspaceID": fixture.targetWorkspace.id.uuidString,
            "palette.copyWorkspaceIDAndRef": fixture.targetWorkspace.id.uuidString,
            "palette.copyWorkspaceLink": WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(
                workspaceId: fixture.targetWorkspace.stableId
            ),
            "palette.copyPaneID": paneID.uuidString,
            "palette.copyPaneLink": WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                workspaceId: fixture.targetWorkspace.stableId,
                paneId: paneID
            ),
            "palette.copySurfaceID": fixture.targetPanelID.uuidString,
            "palette.copySurfaceLink": WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: fixture.targetWorkspace.stableId,
                surfaceId: panel.stableSurfaceId
            ),
            "palette.copyIdentifiers": fixture.targetPanelID.uuidString,
        ]

        for (commandID, expectedSubstring) in expectedSubstringByCommandID {
            pasteboard.clearContents()
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .completed)
            #expect(pasteboard.string(forType: .string)?.contains(expectedSubstring) == true)
            #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
            #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
        }

        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))
        _ = pasteboard.clearContents()
        #expect(pasteboard.setString("unchanged", forType: .string))
        for commandID in expectedSubstringByCommandID.keys {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .targetUnavailable)
            #expect(pasteboard.string(forType: .string) == "unchanged")
        }
    }

    @Test func identifierCopyWriteFailureHasATypedOutcome() {
        #expect(
            ContentView.identifierCopyExecutionResult(didWrite: false)
                == .failed(
                    code: "clipboard_write_failed",
                    message: String(
                        localized: "action.error.identifierCopyFailed",
                        defaultValue: "The identifiers could not be copied."
                    )
                )
        )
    }

    @Test func viewHandlersReportExactOutcomesWithoutChangingSelection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var taskManagerPresentations = 0
        var sleepyModePresentations = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerViewCommandHandlers(
            &registry,
            context: fixture.context,
            showTaskManager: { taskManagerPresentations += 1 },
            activateSleepyMode: { sleepyModePresentations += 1 }
        )

        let invocation = CmuxActionInvocation(source: .automation)
        let triggerFlash = try #require(registry.handler(for: "palette.triggerFlash"))
        let openTaskManager = try #require(registry.handler(for: "palette.openTaskManager"))
        let activateSleepyMode = try #require(registry.handler(for: "palette.sleepyMode"))
        #expect(triggerFlash(invocation) == .completed)
        #expect(openTaskManager(invocation) == .presented)
        #expect(activateSleepyMode(invocation) == .presented)
        #expect(taskManagerPresentations == 1)
        #expect(sleepyModePresentations == 1)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)

        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))
        for commandID in ["palette.triggerFlash", "palette.openTaskManager", "palette.sleepyMode"] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(invocation) == .targetUnavailable)
        }
        #expect(taskManagerPresentations == 1)
        #expect(sleepyModePresentations == 1)
    }

    @Test func tabPinHandlerReportsQueuedUntilRemoteMirrorVerification() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let workspace = fixture.targetWorkspace
        let targetPanelID = fixture.nonTargetPanelID
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let orderBefore = workspace.bonsplitController.tabs(inPane: paneID)
            .compactMap { workspace.panelIdFromSurfaceId($0.id) }
        workspace.isRemoteTmuxMirror = true
        var verification: ((Bool) -> Void)?
        workspace.remoteTmuxWindowOrderSync = { _, completion in
            verification = completion
            return true
        }
        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: fixture.windowID,
                workspaceID: workspace.id,
                panelID: targetPanelID
            ),
            tabManager: fixture.tabManager,
            owningWindowID: fixture.windowID
        )
        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: context,
            configCatalog: emptyCatalog
        )
        let handler = try #require(registry.handler(for: "palette.toggleTabPin"))
        let invocation = CmuxActionInvocation(
            source: .automation,
            arguments: ["pinned": "true"]
        )

        #expect(handler(invocation) == .queued)
        #expect(handler(invocation) == .queued)
        #expect(workspace.isPanelPinned(targetPanelID))

        verification?(false)

        #expect(!workspace.isPanelPinned(targetPanelID))
        #expect(workspace.reorderRemoteTmuxMirrorTabs(toPanelOrder: orderBefore))
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalAttachmentHandlerReportsQueuedAndQueueFull() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }
        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstTargetURL = directoryURL.appendingPathComponent("first-target.txt")
        let firstURL = directoryURL.appendingPathComponent("first.txt")
        #expect(FileManager.default.createFile(atPath: firstTargetURL.path, contents: Data()))
        try FileManager.default.createSymbolicLink(
            at: firstURL,
            withDestinationURL: firstTargetURL
        )

        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer { finishedContinuation.finish() }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            terminalAttachmentDidFinish: { didAttach in
                finishedContinuation.yield(didAttach)
            }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )
        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": firstURL.path]
        )) == .queued)
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        terminalPanel.preserveTextBoxContentForUnmount(from: textView)
        textBoxWindow.close()

        let fillerURLs = (0..<TerminalPanel.maximumPendingTextBoxAttachmentCount).map {
            directoryURL.appendingPathComponent("filler-\($0).txt")
        }
        #expect(terminalPanel.attachFilesToTextBoxInput(fillerURLs) == .queued)
        let overflowURL = directoryURL.appendingPathComponent("overflow.txt")
        #expect(FileManager.default.createFile(atPath: overflowURL.path, contents: Data()))

        guard case .failed(let code, _) = handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": overflowURL.path]
        )) else {
            Issue.record("Expected the attachment handler to report a full queue")
            return
        }
        #expect(code == "attachment_queue_full")
    }

    @Test(.timeLimit(.minutes(1)))
    func terminalAttachmentHandlerRejectsSpecialFilesWithoutBlocking() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        let fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-attachment-\(UUID().uuidString).png")
        let makeFIFOResult: Int32 = fifoURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(0o600))
        }
        #expect(makeFIFOResult == 0)
        defer { try? FileManager.default.removeItem(at: fifoURL) }

        let specialFileURLs = [
            fifoURL,
            URL(fileURLWithPath: "/dev/null"),
        ]
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 2,
            perComposerConcurrentCount: 2,
            globalReservedBytes: 64 * 1024 * 1024,
            perComposerReservedBytes: 64 * 1024 * 1024,
            maximumQueuedCount: 2
        ))
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer { finishedContinuation.finish() }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            terminalAttachmentBudget: budget,
            terminalAttachmentDidFinish: { didAttach in
                finishedContinuation.yield(didAttach)
            }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )
        for specialFileURL in specialFileURLs {
            #expect(handler(CmuxActionInvocation(
                source: .automation,
                arguments: ["path": specialFileURL.path]
            )) == .queued)
        }
        var finishedIterator = finishedStream.makeAsyncIterator()
        for _ in specialFileURLs {
            #expect(await finishedIterator.next() == false)
        }

        #expect(terminalPanel.isTextBoxActive)
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
                && snapshot.queuedCount == 0
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func suspendedAttachmentPreparationKeepsMainActorResponsive() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-palette-suspended-\(UUID().uuidString).txt")
        try Data("fixture".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let maybePreparedFile = await TextBoxPreparedFileAttachment.prepare(fileURL: fileURL)
        let preparedFile = try #require(maybePreparedFile)
        let (_, textBoxWindow) = mountTextBoxInput(
            for: try #require(
                fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
            )
        )
        defer { textBoxWindow.close() }

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        let preparationGate = CommandPaletteAttachmentPreparationGate()
        defer {
            preparationGate.release()
            startedContinuation.finish()
            finishedContinuation.finish()
        }

        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            terminalAttachmentPreparer: { _, _ in
                startedContinuation.yield()
                #expect(preparationGate.waitForRelease())
                return preparedFile
            },
            terminalAttachmentDidFinish: { didAttach in
                finishedContinuation.yield(didAttach)
            }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )
        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": fileURL.path]
        )) == .queued)

        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        // Reaching this MainActor line while preparation is synchronously
        // suspended proves the preparer did not occupy the UI executor.
        preparationGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        let didAttach = await finishedIterator.next()
        #expect(didAttach == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func preparedAttachmentCommitsOnlyAfterConfirmedWindowMount() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        terminalPanel.registerTextBoxInputView(textView)
        #expect(textView.window == nil)

        let fileURL = URL(fileURLWithPath: "/tmp/cmux-hidden-prepared.txt")
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        let (preparedStream, preparedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            preparedContinuation.finish()
            finishedContinuation.finish()
        }
        var completionValues: [Bool] = []
        #expect(terminalPanel.prepareAndAttachFileToTextBoxInputForTesting(
            fileURL,
            using: { url, _ in
                let preparedFile = preparedAttachmentFixture(fileURL: url)
                preparedContinuation.yield()
                return preparedFile
            },
            target: .local,
            budget: budget,
            completion: {
                completionValues.append($0)
                finishedContinuation.yield($0)
            }
        ) == .queued)

        var preparedIterator = preparedStream.makeAsyncIterator()
        try #require(await preparedIterator.next() != nil)
        #expect(textView.pendingAttachmentUploadPlaceholderIDs().isEmpty)
        #expect(textView.inlineAttachments().isEmpty)
        #expect(completionValues.isEmpty)

        let window = NSWindow(
            contentRect: textView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        defer { window.close() }

        // AppKit has attached the view, but the panel has not yet observed the
        // move-to-window callback. Preparation must remain invisible.
        #expect(textView.pendingAttachmentUploadPlaceholderIDs().isEmpty)
        #expect(textView.inlineAttachments().isEmpty)
        #expect(completionValues.isEmpty)

        terminalPanel.textBoxInputViewDidMoveToWindow(textView)
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        #expect(completionValues == [true])
        #expect(textView.pendingAttachmentUploadPlaceholderIDs().isEmpty)
        #expect(textView.inlineAttachments().compactMap(\.localURL) == [fileURL])
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteAttachmentUploadsValidatedDescriptorSnapshotAfterSymlinkSwap() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-remote-attachment-swap-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let validatedTargetURL = directoryURL.appendingPathComponent("validated.txt")
        let swappedTargetURL = directoryURL.appendingPathComponent("swapped.txt")
        let sourceLinkURL = directoryURL.appendingPathComponent("upload-name.txt")
        let replacementLinkURL = directoryURL.appendingPathComponent("replacement-link.txt")
        let validatedBytes = Data("descriptor-validated".utf8)
        let swappedBytes = Data("path-swapped".utf8)
        try validatedBytes.write(to: validatedTargetURL)
        try swappedBytes.write(to: swappedTargetURL)
        try FileManager.default.createSymbolicLink(
            at: sourceLinkURL,
            withDestinationURL: validatedTargetURL
        )
        try FileManager.default.createSymbolicLink(
            at: replacementLinkURL,
            withDestinationURL: swappedTargetURL
        )

        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 1
        ))
        var uploadedSnapshotURL: URL?
        var uploadedSnapshotBytes: Data?
        var completionValues: [Bool] = []
        #expect(terminalPanel.prepareAndAttachFileToTextBoxInputForTesting(
            sourceLinkURL,
            using: { fileURL, target in
                await TextBoxPreparedFileAttachment.prepare(
                    fileURL: fileURL,
                    uploadTarget: target,
                    afterDescriptorValidation: {
                        let renameResult = replacementLinkURL.path.withCString {
                            replacementPath in
                            sourceLinkURL.path.withCString { sourcePath in
                                Darwin.rename(replacementPath, sourcePath)
                            }
                        }
                        precondition(renameResult == 0)
                    }
                )
            },
            target: .remote(.workspaceRemote),
            remoteUploader: { fileURL, _, completion in
                uploadedSnapshotURL = fileURL
                uploadedSnapshotBytes = try? Data(contentsOf: fileURL)
                completion(.success(["/remote/upload-name.txt"]))
            },
            budget: budget,
            completion: { completionValues.append($0) }
        ) == .queued)

        await waitUntil { completionValues == [true] }
        let snapshotURL = try #require(uploadedSnapshotURL)
        defer {
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(
                at: snapshotURL.deletingLastPathComponent()
            )
        }
        #expect(snapshotURL != sourceLinkURL.standardizedFileURL)
        #expect(snapshotURL.lastPathComponent == sourceLinkURL.lastPathComponent)
        #expect(uploadedSnapshotBytes == validatedBytes)
        #expect(try Data(contentsOf: sourceLinkURL) == swappedBytes)
        #expect(try Data(contentsOf: validatedTargetURL) == validatedBytes)
        #expect(try Data(contentsOf: swappedTargetURL) == swappedBytes)

        let attachment = try #require(textView.inlineAttachments().first)
        #expect(attachment.displayName == sourceLinkURL.lastPathComponent)
        #expect(attachment.localURL == snapshotURL)
        #expect(attachment.submissionPath == "/remote/upload-name.txt")
        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))

        let snapshotDirectoryURL = snapshotURL.deletingLastPathComponent()
        textView.clearContent(cleanupAttachmentFiles: true)
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectoryURL.path))
        #expect(try Data(contentsOf: sourceLinkURL) == swappedBytes)
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preparedAttachmentsCommitInInvocationOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }

        let firstURL = URL(fileURLWithPath: "/tmp/cmux-first-prepared.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/cmux-second-prepared.txt")
        let firstPrepared = TextBoxPreparedFileAttachment(
            fileURL: firstURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        let secondPrepared = TextBoxPreparedFileAttachment(
            fileURL: secondURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0,
            localFileDisposition: .callerOwned
        )
        let firstGate = CommandPaletteAttachmentPreparationGate()
        let secondGate = CommandPaletteAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<URL>.makeStream()
        let (preparedStream, preparedContinuation) = AsyncStream<URL>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            firstGate.release()
            secondGate.release()
            startedContinuation.finish()
            preparedContinuation.finish()
            finishedContinuation.finish()
        }
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 2,
            perComposerConcurrentCount: 2,
            globalReservedBytes: 64 * 1024 * 1024,
            perComposerReservedBytes: 64 * 1024 * 1024,
            maximumQueuedCount: 64
        ))
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { url, _ in
                startedContinuation.yield(url)
                if url == firstURL {
                    #expect(firstGate.waitForRelease())
                    preparedContinuation.yield(url)
                    return firstPrepared
                }
                #expect(secondGate.waitForRelease())
                preparedContinuation.yield(url)
                return secondPrepared
            },
            terminalAttachmentBudget: budget,
            terminalAttachmentDidFinish: { didAttach in
                finishedContinuation.yield(didAttach)
            }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )

        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": firstURL.path]
        )) == .queued)
        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": secondURL.path]
        )) == .queued)

        var startedIterator = startedStream.makeAsyncIterator()
        var startedURLs = Set<URL>()
        while startedURLs.count < 2 {
            startedURLs.insert(try #require(await startedIterator.next()))
        }
        secondGate.release()
        var preparedIterator = preparedStream.makeAsyncIterator()
        #expect(await preparedIterator.next() == secondURL)
        #expect(textView.inlineAttachments().isEmpty)

        firstGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        #expect(await finishedIterator.next() == true)
        #expect(
            textView.inlineAttachments().compactMap(\.localURL)
                == [firstURL, secondURL]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func preparedAttachmentKeepsItsInvocationAnchorAcrossTypingAndReattachment() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (originalTextView, originalWindow) = mountTextBoxInput(for: terminalPanel)
        originalTextView.string = "left right"
        originalTextView.setSelectedRange(NSRange(location: 4, length: 0))

        let fileURL = URL(fileURLWithPath: "/tmp/cmux-anchored-prepared.txt")
        let preparedFile = preparedAttachmentFixture(fileURL: fileURL)
        let preparationGate = CommandPaletteAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            preparationGate.release()
            startedContinuation.finish()
            finishedContinuation.finish()
            originalWindow.close()
        }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { _, _ in
                startedContinuation.yield()
                #expect(preparationGate.waitForRelease())
                return preparedFile
            },
            terminalAttachmentDidFinish: { finishedContinuation.yield($0) }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )

        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": fileURL.path]
        )) == .queued)
        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)

        originalTextView.setSelectedRange(
            NSRange(location: originalTextView.attributedString().length, length: 0)
        )
        originalTextView.insertText(
            " tail",
            replacementRange: originalTextView.selectedRange()
        )
        terminalPanel.preserveTextBoxContentForUnmount(from: originalTextView)
        originalWindow.close()

        let (reattachedTextView, reattachedWindow) = mountTextBoxInput(for: terminalPanel)
        defer { reattachedWindow.close() }
        #expect(reattachedTextView.pendingAttachmentUploadPlaceholderIDs().count == 1)

        preparationGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        #expect(
            reattachedTextView.submissionText()
                == "left\(TextBoxAttachment.submissionText(forPath: fileURL.path)) right tail"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func preparedAttachmentFollowsThePanelWhenItMovesWorkspaces() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-moved-prepared.txt")
        let preparedFile = preparedAttachmentFixture(fileURL: fileURL)
        let preparationGate = CommandPaletteAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            preparationGate.release()
            startedContinuation.finish()
            finishedContinuation.finish()
        }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { _, _ in
                startedContinuation.yield()
                #expect(preparationGate.waitForRelease())
                return preparedFile
            },
            terminalAttachmentDidFinish: { finishedContinuation.yield($0) }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )

        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": fileURL.path]
        )) == .queued)
        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)

        let transfer = try #require(
            fixture.targetWorkspace.detachSurface(panelId: terminalPanel.id)
        )
        let destinationPane = try #require(
            fixture.selectedWorkspace.bonsplitController.allPaneIds.first
        )
        #expect(
            fixture.selectedWorkspace.attachDetachedSurface(
                transfer,
                inPane: destinationPane,
                focus: false
            ) == terminalPanel.id
        )
        #expect(fixture.selectedWorkspace.panels[terminalPanel.id] === terminalPanel)

        preparationGate.release()
        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == true)
        #expect(textView.inlineAttachments().compactMap(\.localURL) == [fileURL])
    }

    @Test(.timeLimit(.minutes(1)))
    func attachmentDeadlineSettlesInOrderAndIgnoresLatePreparation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }
        let headURL = URL(fileURLWithPath: "/tmp/cmux-deadline-head.txt")
        let followerURL = URL(fileURLWithPath: "/tmp/cmux-deadline-follower.txt")
        let headPreparedFile = preparedAttachmentFixture(fileURL: headURL)
        let followerPreparedFile = preparedAttachmentFixture(fileURL: followerURL)
        let headPreparationGate = CommandPaletteAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (returnedStream, returnedContinuation) = AsyncStream<Void>.makeStream()
        let (followerPreparedStream, followerPreparedContinuation) =
            AsyncStream<Void>.makeStream()
        let (headDeadlineStream, headDeadlineContinuation) = AsyncStream<Void>.makeStream()
        let (followerDeadlineStream, followerDeadlineContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) =
            AsyncStream<(String, Bool)>.makeStream()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 2,
            perComposerConcurrentCount: 2,
            globalReservedBytes: 64 * 1024 * 1024,
            perComposerReservedBytes: 64 * 1024 * 1024,
            maximumQueuedCount: 64
        ))
        defer {
            headPreparationGate.release()
            headDeadlineContinuation.finish()
            followerDeadlineContinuation.finish()
            startedContinuation.finish()
            returnedContinuation.finish()
            followerPreparedContinuation.finish()
            finishedContinuation.finish()
        }
        var headRegistry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &headRegistry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { _, _ in
                startedContinuation.yield()
                #expect(headPreparationGate.waitForRelease())
                returnedContinuation.yield()
                return headPreparedFile
            },
            terminalAttachmentBudget: budget,
            terminalAttachmentDeadlineWaiter: {
                for await _ in headDeadlineStream {
                    return
                }
                throw CancellationError()
            },
            terminalAttachmentDidFinish: {
                finishedContinuation.yield(("head", $0))
            }
        )
        var followerRegistry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &followerRegistry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { _, _ in
                followerPreparedContinuation.yield()
                return followerPreparedFile
            },
            terminalAttachmentBudget: budget,
            terminalAttachmentDeadlineWaiter: {
                for await _ in followerDeadlineStream {
                    return
                }
                throw CancellationError()
            },
            terminalAttachmentDidFinish: {
                finishedContinuation.yield(("follower", $0))
            }
        )
        let headHandler = try #require(
            headRegistry.handler(for: "palette.terminalAttachTextBoxFile")
        )
        let followerHandler = try #require(
            followerRegistry.handler(for: "palette.terminalAttachTextBoxFile")
        )

        #expect(headHandler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": headURL.path]
        )) == .queued)
        #expect(followerHandler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": followerURL.path]
        )) == .queued)
        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        var followerPreparedIterator = followerPreparedStream.makeAsyncIterator()
        try #require(await followerPreparedIterator.next() != nil)
        #expect(textView.inlineAttachments().isEmpty)
        headDeadlineContinuation.yield()

        var finishedIterator = finishedStream.makeAsyncIterator()
        let firstFinished = try #require(await finishedIterator.next())
        let secondFinished = try #require(await finishedIterator.next())
        #expect(firstFinished.0 == "head")
        #expect(firstFinished.1 == false)
        #expect(secondFinished.0 == "follower")
        #expect(secondFinished.1 == true)
        #expect(textView.pendingAttachmentUploadPlaceholderIDs().isEmpty)
        #expect(textView.inlineAttachments().compactMap(\.localURL) == [followerURL])

        headPreparationGate.release()
        var returnedIterator = returnedStream.makeAsyncIterator()
        try #require(await returnedIterator.next() != nil)
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
        }
        #expect(textView.inlineAttachments().compactMap(\.localURL) == [followerURL])
    }

    @Test(.timeLimit(.minutes(1)))
    func closingPanelCancelsAttachmentAndRejectsItsLateOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let (textView, textBoxWindow) = mountTextBoxInput(for: terminalPanel)
        defer { textBoxWindow.close() }
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-closed-prepared.txt")
        let preparedFile = preparedAttachmentFixture(fileURL: fileURL)
        let preparationGate = CommandPaletteAttachmentPreparationGate()
        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (returnedStream, returnedContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 1,
            perComposerConcurrentCount: 1,
            globalReservedBytes: 32 * 1024 * 1024,
            perComposerReservedBytes: 32 * 1024 * 1024,
            maximumQueuedCount: 64
        ))
        defer {
            preparationGate.release()
            startedContinuation.finish()
            returnedContinuation.finish()
            finishedContinuation.finish()
        }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyActionCatalog(),
            terminalAttachmentPreparer: { _, _ in
                startedContinuation.yield()
                #expect(preparationGate.waitForRelease())
                returnedContinuation.yield()
                return preparedFile
            },
            terminalAttachmentBudget: budget,
            terminalAttachmentDidFinish: { finishedContinuation.yield($0) }
        )
        let handler = try #require(
            registry.handler(for: "palette.terminalAttachTextBoxFile")
        )

        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["path": fileURL.path]
        )) == .queued)
        var startedIterator = startedStream.makeAsyncIterator()
        try #require(await startedIterator.next() != nil)
        terminalPanel.close()

        var finishedIterator = finishedStream.makeAsyncIterator()
        #expect(await finishedIterator.next() == false)
        preparationGate.release()
        var returnedIterator = returnedStream.makeAsyncIterator()
        try #require(await returnedIterator.next() != nil)
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
        }
        #expect(textView.inlineAttachments().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func retainedPreparedBytesAndDuplicateCallersStayBounded() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let budget = TextBoxAttachmentPreparationBudget(limits: .init(
            globalConcurrentCount: 4,
            perComposerConcurrentCount: 2,
            globalReservedBytes: 128 * 1024 * 1024,
            perComposerReservedBytes: 64 * 1024 * 1024,
            maximumQueuedCount: 64
        ))
        let (deadlineStream, deadlineContinuation) = AsyncStream<Void>.makeStream()
        defer { deadlineContinuation.finish() }
        var completionCount = 0
        let urls = (0..<TerminalPanel.maximumPendingTextBoxAttachmentCount).map {
            URL(fileURLWithPath: "/tmp/cmux-budgeted-prepared-\($0).txt")
        }

        for url in urls {
            #expect(terminalPanel.prepareAndAttachFileToTextBoxInputForTesting(
                url,
                using: { url, _ in preparedAttachmentFixture(fileURL: url) },
                budget: budget,
                deadlineWaiter: {
                    for await _ in deadlineStream {
                        return
                    }
                    throw CancellationError()
                },
                completion: { _ in completionCount += 1 }
            ) == .queued)
        }
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 2
                && snapshot.globalReservedBytes == 64 * 1024 * 1024
                && snapshot.queuedCount == urls.count - 2
        }
        #expect(terminalPanel.prepareAndAttachFileToTextBoxInputForTesting(
            urls[0],
            using: { url, _ in preparedAttachmentFixture(fileURL: url) },
            budget: budget,
            deadlineWaiter: { throw CancellationError() },
            completion: { _ in completionCount += 1 }
        ) == .queueFull)

        terminalPanel.close()
        #expect(completionCount == urls.count)
        await waitUntilAsync {
            let snapshot = await budget.snapshot()
            return snapshot.globalConcurrentCount == 0
                && snapshot.globalReservedBytes == 0
                && snapshot.queuedCount == 0
        }
    }

    @Test func proPresentationOutcomesAreTyped() {
        #expect(
            ContentView.commandPaletteProPresentationResult(
                targetAvailable: true,
                didPresent: true
            ) == .presented
        )
        #expect(
            ContentView.commandPaletteProPresentationResult(
                targetAvailable: false,
                didPresent: false
            ) == .targetUnavailable
        )
        #expect(
            ContentView.commandPaletteProPresentationResult(
                targetAvailable: true,
                didPresent: false
            ) == .failed(
                code: "presentation_failed",
                message: String(
                    localized: "action.error.configuredActionFailed",
                    defaultValue: "The configured action could not be started."
                )
            )
        )
    }

    @Test func proHandlersReportInjectedPresentationFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerProCommandHandlers(
            &registry,
            context: fixture.context,
            presentUpgrade: { _, _ in false },
            presentWelcomeChecklist: { _, _ in false }
        )

        let invocation = CmuxActionInvocation(source: .automation)
        for commandID in [
            ContentView.commandPaletteProUpgradeCommandId,
            ContentView.commandPaletteProWelcomeChecklistCommandId,
        ] {
            let handler = try #require(registry.handler(for: commandID))
            guard case .failed(let code, _) = handler(invocation) else {
                Issue.record("Expected a typed Pro presentation failure")
                continue
            }
            #expect(code == "presentation_failed")
        }
    }

    @Test func proPresentersPropagateBrowserEnabledFallbackFailure() {
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(
            forKey: BrowserAvailabilitySettings.disabledKey
        )
        let previousAppDelegate = AppDelegate.shared
        AppDelegate.shared = nil
        BrowserAvailabilitySettings.setDisabled(false)
        defer {
            AppDelegate.shared = previousAppDelegate
            if let previousBrowserDisabled {
                defaults.set(
                    previousBrowserDisabled,
                    forKey: BrowserAvailabilitySettings.disabledKey
                )
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            NotificationCenter.default.post(
                name: BrowserAvailabilitySettings.didChangeNotification,
                object: nil
            )
        }

        var attemptedURLs: [URL] = []
        let failingExternalOpener: (URL) -> Bool = { url in
            attemptedURLs.append(url)
            return false
        }

        #expect(!ProUpgradePresenter.present(openExternalURL: failingExternalOpener))
        #expect(!ProWelcomeChecklistPresenter.present(
            openExternalURL: failingExternalOpener
        ))
        #expect(attemptedURLs.count == 2)
    }

    @Test func proHandlersRejectAStaleExactPanelBeforePresentation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerProCommandHandlers(
            &registry,
            context: fixture.context
        )
        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))

        let invocation = CmuxActionInvocation(source: .automation)
        for commandID in [
            ContentView.commandPaletteProUpgradeCommandId,
            ContentView.commandPaletteProWelcomeChecklistCommandId,
        ] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(invocation) == .targetUnavailable)
        }
    }

    @Test func cmuxOwnedHandlerIDsReserveFeatureOffAndDynamicActions() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let flags = CmuxFeatureFlags.shared
        let agentChatFlag = try #require(
            CmuxFeatureFlags.allFlags.first { $0.key == "agent-chat-ui-enabled-release" }
        )
        let previousAgentChatOverride = flags.overrideValue(for: agentChatFlag)
        flags.setOverride(false, for: agentChatFlag)
        defer { flags.setOverride(previousAgentChatOverride, for: agentChatFlag) }

        let extensionsKey = BetaFeaturesCatalogSection().extensions.userDefaultsKey
        let previousExtensionsValue = UserDefaults.standard.object(forKey: extensionsKey)
        UserDefaults.standard.set(false, forKey: extensionsKey)
        defer {
            if let previousExtensionsValue {
                UserDefaults.standard.set(previousExtensionsValue, forKey: extensionsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: extensionsKey)
            }
        }

        let emptyCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog
        )

        let agentChatID = "palette.newAgentChat"
        let hostedExtensionID = ContentView.commandPaletteExtensionSidebarCommandID(
            CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        )
        #expect(ContentView.commandPaletteNewAgentChatContributions().isEmpty)
        #expect(!CmuxExtensionSidebarSelection.descriptors.contains {
            $0.id == CmuxExtensionSidebarSelection.hostedExtensionsProviderId
        })

        let representativeOwnedIDs: Set<String> = [
            ContentView.commandPaletteAuthSignInCommandId,
            ContentView.commandPaletteCloudOpenCommandId,
            agentChatID,
            "palette.canvas.toggleLayout",
            CommandPaletteSettingsToggleCommands.commandIdPrefix + "workspaceInheritWorkingDirectory",
            "palette.layout.saveCurrent",
            hostedExtensionID,
        ]
        #expect(representativeOwnedIDs.isSubset(of: registry.commandIDs))

        var beeps = 0
        var agentChatRegistry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAgentChatCommandPaletteHandler(
            &agentChatRegistry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            beep: { beeps += 1 }
        )
        let agentChatHandler = try #require(agentChatRegistry.handler(for: agentChatID))
        guard case .failed(let automationCode, _) = agentChatHandler(
            CmuxActionInvocation(source: .automation)
        ) else {
            Issue.record("Expected disabled agent chat to return a typed failure")
            return
        }
        #expect(automationCode == "action_unavailable")
        #expect(beeps == 0)
        _ = agentChatHandler(CmuxActionInvocation(source: .commandPalette))
        #expect(beeps == 1)

        let collidingActions = [agentChatID, hostedExtensionID].map { id in
            CmuxResolvedConfigAction(
                id: id,
                title: id,
                subtitle: nil,
                keywords: [],
                palette: true,
                shortcut: nil,
                icon: nil,
                tooltip: nil,
                action: .command("echo collision"),
                confirm: nil,
                terminalCommandTarget: nil,
                actionSourcePath: "/tmp/cmux.json",
                iconSourcePath: nil,
                newWorkspaceMenu: nil
            )
        }
        let collisionCatalog = CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: collidingActions,
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
        let composition = collisionCatalog.composingPaletteActions(
            reservedActionIDs: registry.commandIDs,
            reservedActionIDPrefixes: ["diagnostic."]
        )

        #expect(composition.actions.isEmpty)
        #expect(Set(composition.issues.compactMap(\.commandName)) == [agentChatID, hostedExtensionID])
    }

    @Test func authSignInQueuesFromTheExactBackgroundTargetWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var presentedWindow: NSWindow?
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { window in
                        presentedWindow = window
                        return true
                    },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignInCommandId)
        )

        #expect(handler(CmuxActionInvocation(source: .automation)) == .queued)
        #expect(presentedWindow === fixture.window)
        #expect(beeps == 0)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
    }

    @Test func authHandlersRejectAStaleExactPanelBeforeStartingWork() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var authLookups = 0
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                authLookups += 1
                return CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { _ in true },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        #expect(fixture.targetWorkspace.closePanel(fixture.targetPanelID, force: true))

        for commandID in [
            ContentView.commandPaletteAuthSignInCommandId,
            ContentView.commandPaletteAuthSignOutCommandId,
        ] {
            let handler = try #require(registry.handler(for: commandID))
            #expect(handler(CmuxActionInvocation(source: .automation)) == .targetUnavailable)
        }
        #expect(authLookups == 0)
        #expect(beeps == 0)
    }

    @Test func authSignOutReportsQueuedOnlyAfterAcceptingWork() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var signOutCalls = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: true,
                    isWorking: false,
                    beginSignIn: { _ in false },
                    signOut: { signOutCalls += 1 }
                )
            }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignOutCommandId)
        )

        #expect(handler(CmuxActionInvocation(source: .automation)) == .queued)
        await Task.yield()
        #expect(signOutCalls == 1)
        #expect(fixture.tabManager.selectedTabId == fixture.selectedWorkspace.id)
        #expect(fixture.targetWorkspace.focusedPanelId == fixture.nonTargetPanelID)
    }

    @Test func authSignInFailureIsTypedAndAutomationDoesNotBeep() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var beeps = 0
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerAuthCommandHandlers(
            &registry,
            context: fixture.context,
            authActions: {
                CommandPaletteAuthActions(
                    isAuthenticated: false,
                    isWorking: false,
                    beginSignIn: { _ in false },
                    signOut: {}
                )
            },
            beep: { beeps += 1 }
        )
        let handler = try #require(
            registry.handler(for: ContentView.commandPaletteAuthSignInCommandId)
        )

        guard case .failed(let code, _) = handler(
            CmuxActionInvocation(source: .automation)
        ) else {
            Issue.record("Expected a typed sign-in failure")
            return
        }
        #expect(code == "auth_sign_in_failed")
        #expect(beeps == 0)

        _ = handler(CmuxActionInvocation(source: .commandPalette))
        #expect(beeps == 1)
    }

    private func mountTextBoxInput(
        for terminalPanel: TerminalPanel
    ) -> (TextBoxInputTextView, NSWindow) {
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        let window = NSWindow(
            contentRect: textView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        terminalPanel.registerTextBoxInputView(textView)
        terminalPanel.textBoxInputViewDidMoveToWindow(textView)
        return (textView, window)
    }

    private func emptyActionCatalog() -> CmuxConfigActionCatalog {
        CmuxConfigActionCatalog(
            loadedCommands: [],
            loadedActions: [],
            commandSourcePaths: [:],
            configurationIssues: [],
            resolvedNewWorkspaceAction: nil,
            resolvedNewWorkspaceCommand: nil,
            configuredNewWorkspaceActionID: nil,
            configuredNewWorkspaceActionSourcePath: nil,
            configuredNewWorkspaceCommandName: nil,
            configuredNewWorkspaceCommandSourcePath: nil
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the expected MainActor state")
    }

    private func waitUntilAsync(
        _ condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the expected async state")
    }

    private func makeFixture() throws -> CommandPaletteTypedViewAndIdentifierFixture {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let targetWorkspace = tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let nonTargetPanel = try #require(
            targetWorkspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: nil
            )
        )
        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        return CommandPaletteTypedViewAndIdentifierFixture(
            previousAppDelegate: previousAppDelegate,
            appDelegate: appDelegate,
            window: window,
            windowID: windowID,
            tabManager: tabManager,
            selectedWorkspace: selectedWorkspace,
            targetWorkspace: targetWorkspace,
            targetPanelID: targetPanelID,
            nonTargetPanelID: nonTargetPanel.id,
            context: context,
            contentView: contentView
        )
    }
}

private final class CommandPaletteAttachmentPreparationGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func waitForRelease() -> Bool {
        semaphore.wait(timeout: .now() + .seconds(30)) == .success
    }

    func release() {
        semaphore.signal()
    }
}

nonisolated private func preparedAttachmentFixture(
    fileURL: URL
) -> TextBoxPreparedFileAttachment {
    TextBoxPreparedFileAttachment(
        fileURL: fileURL,
        thumbnailPixelData: nil,
        thumbnailPixelWidth: 0,
        thumbnailPixelHeight: 0,
        thumbnailBytesPerRow: 0,
        localFileDisposition: .callerOwned
    )
}
