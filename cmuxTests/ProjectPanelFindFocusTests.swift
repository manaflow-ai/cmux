import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// How keyboard focus leaves a project panel's filter field between two
/// Cmd+F presses.
enum ProjectPanelFocusLoss: CaseIterable, Sendable {
    /// The window has no first responder.
    case noResponder
    /// A different view in the window is the first responder.
    case otherView
}

/// Regression coverage for Cmd+F in a focused project panel
/// (https://github.com/manaflow-ai/cmux/issues/6050): the app-level find
/// dispatch must move keyboard focus into the active tab's search field
/// instead of being swallowed, like the Markdown and plain-text preview
/// branches that sit next to it in `TabManager.startSearch()`.
@MainActor
@Suite("Project panel find focus", .serialized)
struct ProjectPanelFindFocusTests {
    /// Cmd+F on the Files tab must focus the filter field, and what the user
    /// types next must land in the panel's files filter.
    @Test
    func startSearchFocusesFilesFilterField() async throws {
        let harness = try await Harness.make(activeTab: .files)
        defer { harness.tearDown() }
        let field = try #require(harness.filterField)
        #expect(!harness.ownsFocus(field), "The filter field must not start focused")
        #expect(harness.panel.filesSearchText.isEmpty)

        try #require(
            harness.manager.startSearch(),
            "Cmd+F must route to a focused project panel instead of being swallowed"
        )
        let focused = await harness.settle { harness.ownsFocus(field) }
        #expect(focused, "Cmd+F must move keyboard focus into the Files tab filter field")

        try harness.type("abc", into: field)
        let typed = await harness.settle { harness.panel.filesSearchText == "abc" }
        #expect(typed, "Typing after Cmd+F must reach the files filter")
    }

    /// Cmd+F on the Build Settings tab must focus its settings filter field.
    @Test
    func startSearchFocusesBuildSettingsFilterField() async throws {
        let harness = try await Harness.make(activeTab: .buildSettings)
        defer { harness.tearDown() }
        let field = try #require(harness.filterField)
        #expect(!harness.ownsFocus(field), "The filter field must not start focused")
        #expect(harness.panel.settingsSearchText.isEmpty)

        try #require(
            harness.manager.startSearch(),
            "Cmd+F must route to a focused project panel instead of being swallowed"
        )
        let focused = await harness.settle { harness.ownsFocus(field) }
        #expect(focused, "Cmd+F must move keyboard focus into the Build Settings filter field")

        try harness.type("abc", into: field)
        let typed = await harness.settle { harness.panel.settingsSearchText == "abc" }
        #expect(typed, "Typing after Cmd+F must reach the settings filter")
    }

    /// A second Cmd+F after focus moved elsewhere must take focus back, however
    /// focus left and whether or not SwiftUI has processed the loss yet; the
    /// request cannot be a one-shot that the first press spends.
    @Test(arguments: ProjectPanelFocusLoss.allCases, [false, true])
    func startSearchRefocusesFilterFieldAfterFocusLeaves(
        loss: ProjectPanelFocusLoss,
        afterLossIsProcessed: Bool
    ) async throws {
        let harness = try await Harness.make(activeTab: .files)
        defer { harness.tearDown() }
        let field = try #require(harness.filterField)

        try #require(harness.manager.startSearch(), "The first Cmd+F must be handled")
        let focusedFirst = await harness.settle { harness.ownsFocus(field) }
        try #require(focusedFirst, "The first Cmd+F must focus the filter field")

        try #require(harness.moveFocusAway(loss), "Focus must be able to leave the filter field")
        let released = await harness.settle { !harness.ownsFocus(field) }
        try #require(released, "Focus must have left the filter field before the second Cmd+F")
        if afterLossIsProcessed {
            await harness.settlePasses()
        }

        try #require(harness.manager.startSearch(), "The second Cmd+F must be handled")
        let focusedAgain = await harness.settle { harness.ownsFocus(field) }
        #expect(focusedAgain, "A second Cmd+F must focus the filter field again")
    }

    /// With two project panels in one workspace, Cmd+F must focus the field of
    /// the focused panel only, whichever of the two that is.
    @Test(arguments: [0, 1])
    func startSearchFocusesOnlyTheFocusedProjectPanel(focusedIndex: Int) async throws {
        let harness = try await Harness.make(activeTab: .files, paneCount: 2, focusedIndex: focusedIndex)
        defer { harness.tearDown() }
        let focusedField = try #require(harness.filterField(at: focusedIndex))
        let otherField = try #require(harness.filterField(at: 1 - focusedIndex))

        try #require(harness.manager.startSearch(), "Cmd+F must be handled by the focused project panel")
        let focused = await harness.settle { harness.ownsFocus(focusedField) }
        #expect(focused, "Cmd+F must focus the filter field of the focused project panel")
        #expect(!harness.ownsFocus(otherField), "Cmd+F must not focus another project panel's field")
    }

    /// Targets and Schemes have no search field: the shortcut must not claim
    /// it there, so routing falls through exactly as before.
    @Test(arguments: [ProjectPanelTab.targets, ProjectPanelTab.schemes])
    func findFallsThroughOnTabsWithoutSearchField(tab: ProjectPanelTab) async throws {
        let harness = try await Harness.make(activeTab: .files)
        defer { harness.tearDown() }
        harness.panel.activeTab = tab
        let unmounted = await harness.settle { harness.filterField == nil }
        try #require(unmounted, "The \(tab) tab must not show a search field")

        #expect(
            !harness.manager.startSearch(),
            "A project tab without a search field must not claim the find shortcut"
        )
    }

    /// While the project model is still loading no tab content is mounted, so
    /// there is no search field to focus and the shortcut must not claim it.
    @Test
    func findFallsThroughWhileProjectModelLoads() throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newProjectSurface(
            inPane: firstPane,
            projectPath: "/nonexistent/cmux-project-panel-find/Missing.xcodeproj",
            focus: true
        ))
        #expect(workspace.focusedPanelId == panel.id)
        // The load started when the surface was created and finishes on a
        // later main-actor turn, so this synchronous read sees it in flight.
        guard case .loading = panel.loadState else {
            Issue.record("The project load must still be in flight, not \(panel.loadState)")
            return
        }

        #expect(
            !manager.startSearch(),
            "A project panel whose model is still loading must not claim the find shortcut"
        )
    }

    /// After a failed load the panel shows an error and no tab content, so
    /// there is still no search field and the shortcut must not claim it.
    @Test
    func findFallsThroughWhenProjectFailedToLoad() async throws {
        let harness = try await Harness.make(fixture: .missing)
        defer { harness.tearDown() }
        guard case .failed = harness.panel.loadState else {
            Issue.record("The missing project must have failed to load, not \(harness.panel.loadState)")
            return
        }
        #expect(harness.filterField == nil)

        #expect(
            !harness.manager.startSearch(),
            "A project panel that failed to load must not claim the find shortcut"
        )
    }
}

/// A view that can take first responder, standing in for any other focus target.
private final class FocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Focused project panels hosted in a standalone window, with their real
/// SwiftUI views mounted so focus requests reach the actual search fields.
///
/// The `TabManager` is built directly instead of through an app main window,
/// so no second copy of the workspace UI mounts and competes for focus.
@MainActor
private final class Harness {
    /// Which project the panels open.
    enum Fixture {
        /// A synthetic project that loads.
        case valid
        /// A path with no project, so the load fails.
        case missing
    }

    struct Pane {
        let panel: ProjectPanel
        let hostingView: NSHostingView<ProjectPanelView>
    }

    let manager: TabManager
    let workspace: Workspace
    let window: NSWindow
    private let panes: [Pane]
    private let focusedIndex: Int
    private let focusProbe: FocusProbeView
    private let fixtureRoot: URL

    private init(
        manager: TabManager,
        workspace: Workspace,
        window: NSWindow,
        panes: [Pane],
        focusedIndex: Int,
        focusProbe: FocusProbeView,
        fixtureRoot: URL
    ) {
        self.manager = manager
        self.workspace = workspace
        self.window = window
        self.panes = panes
        self.focusedIndex = focusedIndex
        self.focusProbe = focusProbe
        self.fixtureRoot = fixtureRoot
    }

    /// Builds `paneCount` project panels in one workspace, focuses the one at
    /// `focusedIndex`, and waits until each has either mounted its filter field
    /// (`.valid`) or failed to load (`.missing`).
    static func make(
        fixture: Fixture = .valid,
        activeTab: ProjectPanelTab = .files,
        paneCount: Int = 1,
        focusedIndex: Int = 0
    ) async throws -> Harness {
        let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("cmux-project-panel-find-\(UUID().uuidString)", isDirectory: true)
        let projectURL = fixtureRoot.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        if fixture == .valid {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try Data(pbxproj.utf8).write(to: projectURL.appendingPathComponent("project.pbxproj"))
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        var window: NSWindow?
        var succeeded = false
        defer {
            // A requirement that throws below must not leak the window, the panels or the fixture.
            if !succeeded {
                window?.orderOut(nil)
                window?.close()
                window?.contentView = nil
                manager.tabs.forEach { $0.teardownAllPanels() }
                try? FileManager.default.removeItem(at: fixtureRoot)
            }
        }
        let firstPane = try #require(workspace.bonsplitController.allPaneIds.first)
        let paneHeight: CGFloat = 300
        let probeHeight: CGFloat = 20
        let container = NSView(frame: NSRect(
            x: 0, y: 0, width: 900, height: probeHeight + paneHeight * CGFloat(paneCount)
        ))
        let focusProbe = FocusProbeView(frame: NSRect(x: 0, y: 0, width: 900, height: probeHeight))
        container.addSubview(focusProbe)

        var panes: [Pane] = []
        for index in 0..<paneCount {
            let panel = try #require(workspace.newProjectSurface(
                inPane: firstPane,
                projectPath: projectURL.path,
                focus: index == focusedIndex
            ))
            panel.activeTab = activeTab
            let hostingView = NSHostingView(rootView: ProjectPanelView(
                panel: panel,
                isFocused: index == focusedIndex,
                onRequestPanelFocus: {}
            ))
            hostingView.frame = NSRect(
                x: 0, y: probeHeight + paneHeight * CGFloat(index), width: 900, height: paneHeight
            )
            container.addSubview(hostingView)
            panes.append(Pane(panel: panel, hostingView: hostingView))
        }

        let hostWindow = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = container
        hostWindow.makeKeyAndOrderFront(nil)
        window = hostWindow

        let harness = Harness(
            manager: manager,
            workspace: workspace,
            window: hostWindow,
            panes: panes,
            focusedIndex: focusedIndex,
            focusProbe: focusProbe,
            fixtureRoot: fixtureRoot
        )
        switch fixture {
        case .valid:
            let ready = await harness.settle {
                panes.indices.allSatisfy { harness.filterField(at: $0) != nil }
            }
            try #require(ready, "Each project panel must load the synthetic project and mount its filter field")
        case .missing:
            let failed = await harness.settle {
                panes.allSatisfy { pane in
                    if case .failed = pane.panel.loadState { return true }
                    return false
                }
            }
            try #require(failed, "Each project panel must fail to load a missing project")
        }
        let intendedPanelID = panes[focusedIndex].panel.id
        let focusSettled = await harness.settle { workspace.focusedPanelId == intendedPanelID }
        try #require(focusSettled, "The intended project panel must be the workspace's focused panel")
        succeeded = true
        return harness
    }

    func tearDown() {
        window.orderOut(nil)
        window.close()
        // Release the hosted views, so their notification subscriptions end with the test.
        window.contentView = nil
        manager.tabs.forEach { $0.teardownAllPanels() }
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    /// The focused project panel.
    var panel: ProjectPanel { panes[focusedIndex].panel }

    /// The only editable text field the focused panel's active tab mounts: its filter.
    var filterField: NSTextField? { filterField(at: focusedIndex) }

    func filterField(at index: Int) -> NSTextField? {
        let fields = editableTextFields(in: panes[index].hostingView)
        return fields.count == 1 ? fields.first : nil
    }

    /// Whether `field` is being edited and owns the window's first responder.
    func ownsFocus(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    /// Types `text` through the field's editor, as keyboard input would.
    func type(_ text: String, into field: NSTextField) throws {
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Takes first responder away from the filter field the given way.
    func moveFocusAway(_ loss: ProjectPanelFocusLoss) -> Bool {
        switch loss {
        case .noResponder:
            return window.makeFirstResponder(nil)
        case .otherView:
            return window.makeFirstResponder(focusProbe)
        }
    }

    /// Lets SwiftUI and queued main-actor work run until `condition` holds,
    /// with a real deadline so a regression fails the expectation instead of
    /// hanging.
    func settle(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            await settlePass()
        }
        return condition()
    }

    /// Runs a few layout and run-loop passes with no condition to wait for, so
    /// SwiftUI has processed what just happened before the test acts again.
    func settlePasses(_ count: Int = 5) async {
        for _ in 0..<count {
            await settlePass()
        }
    }

    /// The test body is itself a main-actor job, so the nested run loop can't
    /// run other main-actor jobs; yielding lets the ones already queued run.
    private func settlePass() async {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        await Task.yield()
    }

    private func editableTextFields(in view: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable {
            fields.append(field)
        }
        for subview in view.subviews {
            fields.append(contentsOf: editableTextFields(in: subview))
        }
        return fields
    }

    private static let pbxproj = """
    // !$*UTF8*$!
    {
        archiveVersion = 1;
        objectVersion = 77;
        objects = {
            P0 = {isa = PBXProject; buildConfigurationList = CL0; mainGroup = G0; targets = (T1); };
            G0 = {isa = PBXGroup; children = (F1); sourceTree = "<group>"; };
            F1 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Main.swift; sourceTree = "<group>"; };
            T1 = {isa = PBXNativeTarget; buildConfigurationList = CL1; buildPhases = (); dependencies = (); name = App; productType = "com.apple.product-type.application"; };
            CL0 = {isa = XCConfigurationList; buildConfigurations = (C0); };
            CL1 = {isa = XCConfigurationList; buildConfigurations = (C1); };
            C0 = {isa = XCBuildConfiguration; buildSettings = {}; name = Debug; };
            C1 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.cmux.fixture; }; name = Debug; };
        };
        rootObject = P0;
    }
    """
}
