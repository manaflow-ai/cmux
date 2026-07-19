import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command deep-link execution planning", .serialized)
struct CmuxRunURLCoordinatorTests {
    @Test func coldStartWorkspaceRunBypassesRestoreDeferral() throws {
        #expect(!CmuxRunURLCoordinator.shouldDeferForStartupRestore(
            request: try workspaceRequest(),
            didAttemptRestore: false,
            isApplyingRestore: false
        ))
    }

    @Test func targetedRunStillWaitsForStartupRestore() throws {
        let request = CmuxRunURLRequest(
            originalURL: try #require(URL(string: "cmux://run")),
            command: "true",
            workingDirectory: "/tmp",
            placement: .surface,
            workspaceId: UUID(),
            anchor: .pane(UUID()),
            direction: nil
        )

        #expect(CmuxRunURLCoordinator.shouldDeferForStartupRestore(
            request: request,
            didAttemptRestore: false,
            isApplyingRestore: false
        ))
        #expect(CmuxRunURLCoordinator.shouldDeferForStartupRestore(
            request: request,
            didAttemptRestore: true,
            isApplyingRestore: true
        ))
    }

    @Test func repeatedBusyFailuresReuseOneModelessWindow() throws {
        let failurePresenter = CmuxRunURLNonModalFailurePresenter()
        let presenter = CmuxRunURLConfirmationPresenter(
            nonModalFailurePresenter: failurePresenter
        )
        failurePresenter.dismiss()
        defer { failurePresenter.dismiss() }

        presenter.showNonModalFailure(.busy)
        let firstWindow = try #require(failurePresenter.window)
        presenter.showNonModalFailure(.busy)

        #expect(failurePresenter.window === firstWindow)
        #expect(NSApp.modalWindow == nil)
    }

    @Test func workspacePlanFreezesTheReceivingWindow() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }

        let request = try workspaceRequest()
        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: request,
            workingDirectory: try resolvedWorkingDirectory()
        )

        guard case .success(let plan) = result else {
            Issue.record("Expected a workspace plan, saw \(result)")
            return
        }
        #expect(
            plan.target == .workspace(
                windowId: windowId,
                tabManagerIdentity: ObjectIdentifier(manager)
            )
        )
        #expect(plan.command == "true")
        #expect(plan.workingDirectory == "/tmp")
    }

    @Test func workspacePlanRemainsAvailableWithoutAnOpenWindow() throws {
        let app = AppDelegate()
        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: try workspaceRequest(),
            workingDirectory: try resolvedWorkingDirectory()
        )

        guard case .success(let plan) = result else {
            Issue.record("Expected a new-window workspace plan, saw \(result)")
            return
        }
        #expect(plan.command == "true")
        #expect(plan.workingDirectory == "/tmp")
        #expect(plan.target == .newWindow)
    }

    @Test func stableSurfaceAnchorResolvesToCurrentPane() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let paneId = try #require(workspace.paneId(forPanelId: panelId)).id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let request = try targetRequest(
            placement: .surface,
            workspaceId: workspace.stableId,
            anchor: .surface(panel.stableSurfaceId),
            direction: nil
        )

        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: request,
            workingDirectory: try resolvedWorkingDirectory()
        )

        guard case .success(let plan) = result else {
            Issue.record("Expected a surface plan, saw \(result)")
            return
        }
        #expect(
            plan.target == .surface(
                windowId: windowId,
                workspaceId: workspace.id,
                paneId: paneId,
                anchorPanelId: panelId
            )
        )
    }

    @Test func approvalTargetSanitizesWorkspaceTitleAndLeadsWithStableIdentifiers() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let paneId = try #require(workspace.paneId(forPanelId: panelId)).id
        workspace.setCustomTitle(
            "Trusted workspace\nFake pane \u{202E}1234 \u{061C}spoof \u{2060}hidden"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let request = try targetRequest(
            placement: .surface,
            workspaceId: workspace.stableId,
            anchor: .surface(panel.stableSurfaceId),
            direction: nil
        )

        let result = CmuxRunURLCoordinator(appDelegate: app).makePlan(
            request: request,
            workingDirectory: try resolvedWorkingDirectory()
        )
        guard case .success(let plan) = result else {
            Issue.record("Expected a surface plan, saw \(result)")
            return
        }

        #expect(!plan.targetDescription.contains("\n"))
        #expect(!plan.targetDescription.contains("\u{202E}"))
        #expect(!plan.targetDescription.contains("\u{061C}"))
        #expect(!plan.targetDescription.contains("\u{2060}"))
        #expect(plan.targetDescription.contains(String(windowId.uuidString.prefix(8))))
        #expect(plan.targetDescription.contains(String(workspace.id.uuidString.prefix(8))))
        let paneToken = String(paneId.uuidString.prefix(8))
        #expect(plan.targetDescription.contains(paneToken))
        #expect(
            plan.targetDescription.range(of: paneToken)!.lowerBound
                < plan.targetDescription.range(of: "Trusted workspace")!.lowerBound
        )
    }

    @Test func remoteTmuxWorkspaceIsRejectedBeforeApproval() throws {
        let app = AppDelegate()
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        workspace.isRemoteTmuxMirror = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            workspace.isRemoteTmuxMirror = false
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let request = try targetRequest(
            placement: .surface,
            workspaceId: workspace.stableId,
            anchor: .surface(panel.stableSurfaceId),
            direction: nil
        )

        #expect(
            CmuxRunURLCoordinator(appDelegate: app).makePlan(
                request: request,
                workingDirectory: try resolvedWorkingDirectory()
            ) == .failure(.remoteWorkspaceUnsupported)
        )
    }

    @Test func approvedWorkspacePlanCreatesExactlyOneWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        let app = AppDelegate()
        let manager = TabManager()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let initialCount = manager.tabs.count
        let workingDirectory = try resolvedWorkingDirectory()
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: workingDirectory.path,
            workingDirectoryIdentity: workingDirectory.identity,
            target: .workspace(
                windowId: windowId,
                tabManagerIdentity: ObjectIdentifier(manager)
            ),
            placementDescription: "New workspace",
            targetDescription: "Test window"
        )

        switch await CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected workspace creation to succeed, saw \(error)")
        }
        #expect(manager.tabs.count == initialCount + 1)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelId)?.surface)
        #expect(terminal.debugInitialCommand() == plan.launchCommand)
        #expect(terminal.debugInitialInputForTesting() == nil)
        }
    }

    @Test func approvedNewWindowPlanSubmitsTheReviewedCommand() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        let app = AppDelegate()
        let workingDirectory = try resolvedWorkingDirectory()
        let plan = CmuxRunExecutionPlan(
            command: "printf reviewed",
            workingDirectory: workingDirectory.path,
            workingDirectoryIdentity: workingDirectory.identity,
            target: .newWindow,
            placementDescription: "New workspace",
            targetDescription: "New window"
        )

        switch await CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected new-window creation to succeed, saw \(error)")
        }
        let context = try #require(app.preferredRegisteredMainWindowContext())
        let window = try #require(app.windowForMainWindowId(context.windowId))
        defer {
            app.unregisterMainWindowContextForTesting(windowId: context.windowId)
            window.close()
        }
        let workspace = try #require(context.tabManager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let terminal = try #require(workspace.terminalPanel(for: panelId)?.surface)

        #expect(terminal.debugInitialCommand() == plan.launchCommand)
        #expect(terminal.debugInitialInputForTesting() == nil)
        }
    }

    @Test func approvedSurfacePlanCreatesAndFocusesTabInBackgroundWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        let app = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = manager.addWorkspace(select: false)
        targetWorkspace.workspaceEnvironment = ["BASH_ENV": "/tmp/cmux-unreviewed-startup"]
        let sourcePanelId = try #require(targetWorkspace.focusedPanelId)
        let paneId = try #require(targetWorkspace.paneId(forPanelId: sourcePanelId)).id
        let initialPanelCount = targetWorkspace.panels.count
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let workingDirectory = try resolvedWorkingDirectory()
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: workingDirectory.path,
            workingDirectoryIdentity: workingDirectory.identity,
            target: .surface(
                windowId: windowId,
                workspaceId: targetWorkspace.id,
                paneId: paneId,
                anchorPanelId: sourcePanelId
            ),
            placementDescription: "New tab",
            targetDescription: "Background workspace"
        )

        switch await CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected tab creation to succeed, saw \(error)")
        }
        let newPanelId = try #require(targetWorkspace.focusedPanelId)
        #expect(targetWorkspace.panels.count == initialPanelCount + 1)
        #expect(newPanelId != sourcePanelId)
        #expect(targetWorkspace.paneId(forPanelId: newPanelId)?.id == paneId)
        #expect(manager.selectedTabId == targetWorkspace.id)
        let terminal = try #require(targetWorkspace.terminalPanel(for: newPanelId)?.surface)
        #expect(terminal.debugInitialCommand() == plan.launchCommand)
        #expect(terminal.debugInitialInputForTesting() == nil)
        #expect(terminal.respawnAdditionalEnvironment["BASH_ENV"] == nil)
        }
    }

    @Test func approvedPanePlanCreatesAndFocusesSplitInBackgroundWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        let app = AppDelegate()
        let manager = TabManager()
        let targetWorkspace = manager.addWorkspace(select: false)
        targetWorkspace.workspaceEnvironment = ["BASH_ENV": "/tmp/cmux-unreviewed-startup"]
        let sourcePanelId = try #require(targetWorkspace.focusedPanelId)
        let sourcePaneId = try #require(targetWorkspace.paneId(forPanelId: sourcePanelId)).id
        let initialPaneCount = targetWorkspace.bonsplitController.allPaneIds.count
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager, window: window)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }
        let workingDirectory = try resolvedWorkingDirectory()
        let plan = CmuxRunExecutionPlan(
            command: "true",
            workingDirectory: workingDirectory.path,
            workingDirectoryIdentity: workingDirectory.identity,
            target: .pane(
                windowId: windowId,
                workspaceId: targetWorkspace.id,
                paneId: sourcePaneId,
                sourcePanelId: sourcePanelId,
                direction: .right
            ),
            placementDescription: "New split",
            targetDescription: "Background workspace"
        )

        switch await CmuxRunURLCoordinator(appDelegate: app).execute(plan) {
        case .success:
            break
        case .failure(let error):
            Issue.record("Expected split creation to succeed, saw \(error)")
        }
        let newPanelId = try #require(targetWorkspace.focusedPanelId)
        #expect(targetWorkspace.bonsplitController.allPaneIds.count == initialPaneCount + 1)
        #expect(newPanelId != sourcePanelId)
        #expect(targetWorkspace.paneId(forPanelId: newPanelId)?.id != sourcePaneId)
        #expect(manager.selectedTabId == targetWorkspace.id)
        let terminal = try #require(targetWorkspace.terminalPanel(for: newPanelId)?.surface)
        #expect(terminal.debugInitialCommand() == plan.launchCommand)
        #expect(terminal.debugInitialInputForTesting() == nil)
        #expect(terminal.respawnAdditionalEnvironment["BASH_ENV"] == nil)
        }
    }

    @Test func reviewedCommandPolicyDropsEveryInheritedStartupInfluence() {
        var inherited = CmuxSurfaceConfigTemplate()
        inherited.fontSize = 17
        inherited.workingDirectory = "/tmp/unreviewed-directory"
        inherited.command = "printf unreviewed-command"
        inherited.environmentVariables = ["BASH_ENV": "/tmp/unreviewed-startup"]
        inherited.initialInput = "printf unreviewed-input\\n"
        inherited.waitAfterCommand = false

        let policy = TerminalStartupInheritancePolicy.reviewedCommand
        let sanitized = policy.configTemplate(from: inherited)

        #expect(sanitized?.fontSize == 17)
        #expect(sanitized?.workingDirectory == nil)
        #expect(sanitized?.command == nil)
        #expect(sanitized?.environmentVariables.isEmpty == true)
        #expect(sanitized?.initialInput == nil)
        #expect(sanitized?.waitAfterCommand == false)
        #expect(policy.environment(
            workspaceEnvironment: ["BASH_ENV": "/tmp/workspace-startup"],
            explicitEnvironment: ["ENV": "/tmp/explicit-startup"]
        ).isEmpty)
        #expect(policy.initialInput("printf hidden\\n") == nil)
        #expect(policy.tmuxStartCommand("tmux hidden") == nil)
    }

    @Test func longApprovalDirectoryIsFullyInspectableAndCopyable() throws {
        let directory = "/private/var/folders/rr/vmfx6xh12dz2tlvgtmyvjmf80000gn/T/"
            + String(repeating: "security-sensitive-segment/", count: 14)
            + "approved-target"
        let row = CmuxRunURLConfirmationPresenter().directoryDetailRow(value: directory)
        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: row))
        let textView = try #require(scrollView.documentView as? NSTextView)

        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.string == directory)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.isHorizontallyResizable)
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(textView.frame.width > 560)
        #expect(scrollView.constraints.contains { constraint in
            constraint.firstAttribute == .height && constraint.constant == 42
        })
    }

    @Test func shortApprovalDirectoryRemainsFullyInspectableAndCopyable() throws {
        let directory = "/tmp/project"
        let row = CmuxRunURLConfirmationPresenter().directoryDetailRow(value: directory)
        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: row))
        let textView = try #require(scrollView.documentView as? NSTextView)

        #expect(textView.string == directory)
        #expect(textView.isSelectable)
    }

    @Test func longApprovalTargetRemainsFullyInspectableAndCopyable() throws {
        let target = "Window 12345678, workspace 23456789, pane 34567890: "
            + String(repeating: "security-sensitive-workspace-title-", count: 20)
        let row = CmuxRunURLConfirmationPresenter().targetDetailRow(value: target)
        let scrollView = try #require(firstSubview(of: NSScrollView.self, in: row))
        let textView = try #require(scrollView.documentView as? NSTextView)

        #expect(scrollView.hasHorizontalScroller)
        #expect(textView.string == target)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.isHorizontallyResizable)
        #expect(textView.textContainer?.widthTracksTextView == false)
        #expect(textView.frame.width > 560)
    }

    private func workspaceRequest() throws -> CmuxRunURLRequest {
        CmuxRunURLRequest(
            originalURL: try #require(URL(string: "cmux://run")),
            command: "true",
            workingDirectory: "/tmp",
            placement: .workspace,
            workspaceId: nil,
            anchor: nil,
            direction: nil
        )
    }

    private func resolvedWorkingDirectory(
        _ path: String = "/tmp"
    ) throws -> CmuxRunResolvedWorkingDirectory {
        try CmuxRunWorkingDirectoryResolver().resolve(path).get()
    }

    private func targetRequest(
        placement: CmuxRunURLPlacement,
        workspaceId: UUID,
        anchor: CmuxRunURLAnchor,
        direction: CmuxRunURLDirection?
    ) throws -> CmuxRunURLRequest {
        CmuxRunURLRequest(
            originalURL: try #require(URL(string: "cmux://run")),
            command: "true",
            workingDirectory: "/tmp",
            placement: placement,
            workspaceId: workspaceId,
            anchor: anchor,
            direction: direction
        )
    }

    private func firstSubview<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let root = root as? View {
            return root
        }
        for subview in root.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
