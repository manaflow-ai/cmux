import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import CmuxUpdater
import Darwin
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

    @Test func terminalAttachmentHandlerReportsQueuedAndQueueFull() async throws {
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

        var handler: CmuxActionHandler?
        await confirmation("regular attachment preparation finished") { finished in
            var registry = CommandPaletteHandlerRegistry()
            fixture.contentView.registerCommandPaletteHandlers(
                &registry,
                context: fixture.context,
                configCatalog: emptyCatalog,
                terminalAttachmentDidFinish: { didAttach in
                    #expect(didAttach)
                    finished()
                }
            )
            guard let registeredHandler = registry.handler(
                for: "palette.terminalAttachTextBoxFile"
            ) else {
                Issue.record("Expected the attachment handler")
                finished()
                return
            }
            handler = registeredHandler
            #expect(registeredHandler(CmuxActionInvocation(
                source: .automation,
                arguments: ["path": firstURL.path]
            )) == .queued)
        }
        let handler = try #require(handler)

        let fillerURLs = (0..<(TerminalPanel.maximumPendingTextBoxAttachmentCount - 1)).map {
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

    @Test func terminalAttachmentHandlerRejectsSpecialFilesWithoutBlocking() async throws {
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
        let makeFIFOResult = fifoURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, mode_t(0o600))
        }
        #expect(makeFIFOResult == 0)
        defer { try? FileManager.default.removeItem(at: fifoURL) }

        let specialFileURLs = [
            fifoURL,
            URL(fileURLWithPath: "/dev/null"),
        ]
        await confirmation(
            "special-file attachment preparation finished",
            expectedCount: specialFileURLs.count
        ) { finished in
            var registry = CommandPaletteHandlerRegistry()
            fixture.contentView.registerCommandPaletteHandlers(
                &registry,
                context: fixture.context,
                configCatalog: emptyCatalog,
                terminalAttachmentDidFinish: { didAttach in
                    #expect(!didAttach)
                    finished()
                }
            )
            guard let handler = registry.handler(for: "palette.terminalAttachTextBoxFile") else {
                Issue.record("Expected the attachment handler")
                for _ in specialFileURLs { finished() }
                return
            }
            for specialFileURL in specialFileURLs {
                #expect(handler(CmuxActionInvocation(
                    source: .automation,
                    arguments: ["path": specialFileURL.path]
                )) == .queued)
            }
        }

        #expect(!terminalPanel.isTextBoxActive)
        let reservations = (0..<TerminalPanel.maximumPendingTextBoxAttachmentCount)
            .compactMap { _ in terminalPanel.reservePreparedTextBoxAttachment() }
        #expect(reservations.count == TerminalPanel.maximumPendingTextBoxAttachmentCount)
    }

    @Test func suspendedAttachmentPreparationKeepsMainActorResponsive() async throws {
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

        let (startedStream, startedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let (finishedStream, finishedContinuation) = AsyncStream<Bool>.makeStream()
        defer {
            startedContinuation.finish()
            releaseContinuation.finish()
            finishedContinuation.finish()
        }

        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerCommandPaletteHandlers(
            &registry,
            context: fixture.context,
            configCatalog: emptyCatalog,
            terminalAttachmentPreparer: { _ in
                #expect(!Thread.isMainThread)
                startedContinuation.yield()
                for await _ in releaseStream {
                    break
                }
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
        _ = await startedIterator.next()
        await confirmation("main actor heartbeat") { heartbeat in
            Task { @MainActor in
                heartbeat()
            }
        }

        releaseContinuation.yield()
        var finishedIterator = finishedStream.makeAsyncIterator()
        let didAttach = await finishedIterator.next()
        #expect(didAttach == true)
    }

    @Test func preparedAttachmentReservationsFlushInInvocationOrder() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let terminalPanel = try #require(
            fixture.targetWorkspace.panels[fixture.targetPanelID] as? TerminalPanel
        )
        let textView = TextBoxInputTextView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 120)
        )
        var insertedFileURLs: [URL] = []
        textView.onInsertPreparedFileAttachments = { preparedFiles, _ in
            insertedFileURLs.append(contentsOf: preparedFiles.map(\.fileURL))
            return true
        }
        let window = NSWindow(
            contentRect: textView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        defer { window.close() }
        terminalPanel.registerTextBoxInputView(textView)
        terminalPanel.textBoxInputViewDidMoveToWindow(textView)

        let firstURL = URL(fileURLWithPath: "/tmp/cmux-first-prepared.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/cmux-second-prepared.txt")
        let firstPrepared = TextBoxPreparedFileAttachment(
            fileURL: firstURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0
        )
        let secondPrepared = TextBoxPreparedFileAttachment(
            fileURL: secondURL,
            thumbnailPixelData: nil,
            thumbnailPixelWidth: 0,
            thumbnailPixelHeight: 0,
            thumbnailBytesPerRow: 0
        )
        let firstReservation = try #require(
            terminalPanel.reservePreparedTextBoxAttachment()
        )
        let secondReservation = try #require(
            terminalPanel.reservePreparedTextBoxAttachment()
        )
        let duplicateSecondReservation = try #require(
            terminalPanel.reservePreparedTextBoxAttachment()
        )

        #expect(terminalPanel.fulfillPreparedTextBoxAttachment(
            reservationID: secondReservation,
            preparedFile: secondPrepared
        ) == .queued)
        #expect(insertedFileURLs.isEmpty)
        #expect(terminalPanel.fulfillPreparedTextBoxAttachment(
            reservationID: duplicateSecondReservation,
            preparedFile: secondPrepared
        ) == .queued)
        #expect(insertedFileURLs.isEmpty)
        #expect(terminalPanel.fulfillPreparedTextBoxAttachment(
            reservationID: firstReservation,
            preparedFile: firstPrepared
        ) == .completed)
        #expect(insertedFileURLs == [firstURL, secondURL])
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

    @Test func proHandlersReportExternalPresentationFailure() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(
            forKey: BrowserAvailabilitySettings.disabledKey
        )
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
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
        var registry = CommandPaletteHandlerRegistry()
        fixture.contentView.registerProCommandHandlers(
            &registry,
            context: fixture.context,
            presentUpgrade: { tabManager, target in
                ProUpgradePresenter.present(
                    tabManager: tabManager,
                    sourceWindowID: target.windowID,
                    sourceWorkspaceID: target.workspaceID,
                    sourcePanelID: target.panelID,
                    openExternalURL: failingExternalOpener
                )
            },
            presentWelcomeChecklist: { tabManager, target in
                ProWelcomeChecklistPresenter.present(
                    tabManager: tabManager,
                    sourceWindowID: target.windowID,
                    sourceWorkspaceID: target.workspaceID,
                    sourcePanelID: target.panelID,
                    openExternalURL: failingExternalOpener
                )
            }
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
