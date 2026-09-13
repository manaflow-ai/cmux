import AppKit
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Contextual Cloud VPN guidance", .serialized)
struct CloudPortsVPNAffordanceTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "test.cloud.vpn")

    @Test("Setup guidance uses supported, explicitly off status")
    func supportedOffStateOnly() {
        #expect(CloudPortsVPNWarning.projection(status: nil) == nil)
        for state in [CloudTunnelState.starting, .awaitingApproval, .up, .stopping, .failed("failure")] {
            #expect(CloudPortsVPNWarning.projection(status: .init(backend: backend, state: state, isPinned: false)) == nil)
        }
        #expect(CloudPortsVPNWarning.projection(status: .init(backend: backend, state: .off, isPinned: false)) != nil)
        #expect(CloudPortsVPNWarning.projection(status: .init(backend: .unavailable(.entitlementMissing), state: .off, isPinned: false)) == nil)
    }

    @Test("The Machines header renders no VPN setup banner when off or connected", arguments: [CloudTunnelState.off, .up])
    func noStandaloneBanner(state: CloudTunnelState) throws {
        let suite = "CloudPortsVPNAffordance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: MachinesPanelBanners(
            tunnelBanner: CloudTunnelBanner(status: .init(backend: backend, state: state, isPinned: false)),
            plan: nil, bannerDismissals: CloudBannerDismissalStore(defaults: defaults), chromeBackgroundColor: .windowBackgroundColor
        ).frame(width: 260))
        #expect(host.fittingSize.height == 0)
    }

    @Test("Only a successful empty port scan shows the configure callout", arguments: [SurfaceLinkState.connected, .notApplicable, .connecting, .error, .asleep, .unavailable])
    func calloutPreservesDiscoveryStates(link: SurfaceLinkState) {
        let node = emptyPorts(link: link)
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions(), showsCloudVPNWarning: true)
        let visibleCallouts = descendants(of: cell).compactMap { $0 as? CloudPortsVPNEmptyStateContent }.filter { !$0.isHidden }
        #expect(visibleCallouts.count == (link == .connected || link == .notApplicable ? 1 : 0))
        if let callout = visibleCallouts.first {
            #expect(callout.setupButton.title == CloudPortsVPNWarning().setupTitle)
            #expect(callout.explanationLabel.stringValue == CloudPortsVPNWarning().explanation)
        }
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions(), showsCloudVPNWarning: false)
        let allHidden = descendants(of: cell).compactMap { $0 as? CloudPortsVPNEmptyStateContent }.allSatisfy { $0.isHidden }
        #expect(allHidden)
    }

    @Test("Reachable port rows keep their normal height and never allocate VPN controls")
    func reachablePortRowsStayCompact() {
        let port = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("test"), port: 3000, directURL: "http://10.0.0.7:3000")
        let node = CloudTreeNode(id: "port", kind: .port(port, url: port.url, openIn: nil))
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions(), showsCloudVPNWarning: true)
        #expect(descendants(of: cell).allSatisfy { !($0 is CloudPortsVPNEmptyStateContent) && !($0 is CloudVPNSetupButton) })
        let outline = NSOutlineView()
        let withWarning = CloudTreeRowHeight(style: .defaultStyle, showsVPNWarning: true)
        let withoutWarning = CloudTreeRowHeight(style: .defaultStyle, showsVPNWarning: false)
        #expect(withWarning.height(of: node, in: outline) == withoutWarning.height(of: node, in: outline))
    }

    @Test("A reused Ports header keeps interactive gray help visible after mouse exit")
    func helpHoverAndAccessibility() throws {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        let node = CloudTreeNode(id: "ports", kind: .portsGroup(machine: .cloud("test")))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions(), showsCloudVPNWarning: true)
        cell.layoutSubtreeIfNeeded()
        let button = try #require(descendants(of: cell).compactMap { $0 as? CloudVPNSetupButton }.first)
        let event = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        cell.mouseExited(with: event)
        #expect(!button.isHidden && button.alphaValue == 1)
        #expect(button.frame.width >= 28 && button.frame.height >= 24)
        #expect(button.contentTintColor == .secondaryLabelColor)
        #expect(button.toolTip == CloudPortsVPNWarning().help)
        #expect(button.accessibilityLabel() == CloudPortsVPNWarning().setupTitle)
        #expect(button.accessibilityIdentifier() == "CloudPortsVPNWarningButton")
        #expect(button.acceptsFirstResponder)
        #expect(button.target === button && button.action != nil)
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions(), showsCloudVPNWarning: false)
        #expect(button.isHidden)
    }

    @Test("Both VPN controls open setup directly and respect disabled state", arguments: [CloudVPNSetupButton.Presentation.text, .helpIcon])
    func controlsOpenSetupDirectly(presentation: CloudVPNSetupButton.Presentation) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let button = CloudVPNSetupButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), presentation: presentation)
        window.contentView = button
        defer { window.contentView = nil }
        var routed: [NSWindow?] = []
        button.setup = { routed.append($0) }
        button.performClick(nil)
        #expect(button.accessibilityPerformPress())
        for keyCode in [UInt16(36), 76, 49] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
            button.keyDown(with: event)
        }
        #expect(routed.count == 5)
        #expect(routed.allSatisfy { $0 === window })
        #expect(button.accessibilityHelp() == CloudPortsVPNWarning().help)
        if presentation == .text {
            #expect(button.title == CloudPortsVPNWarning().setupTitle)
            #expect(button.accessibilityIdentifier() == "CloudPortsVPNEmptyStateSetupButton")
            #expect(button.bezelStyle == .rounded)
        } else {
            #expect(button.image != nil && button.imagePosition == .imageOnly)
            #expect(button.accessibilityIdentifier() == "CloudPortsVPNWarningButton")
            #expect(button.bezelStyle == .inline && button.contentTintColor == .secondaryLabelColor)
        }
        button.isEnabled = false
        #expect(!button.acceptsFirstResponder)
        #expect(!button.accessibilityPerformPress())
        button.performClick(nil)
        let disabledEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: disabledEvent)
        #expect(routed.count == 5)
    }

    @Test("Callout content grows to fit a narrow sidebar", arguments: [140.0, 220.0, 360.0])
    func calloutWraps(width: Double) {
        let height = CloudPortsVPNEmptyStateContent.height(width: width, style: .defaultStyle)
        let callout = CloudPortsVPNEmptyStateContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        callout.configure(style: .defaultStyle, setup: { _ in })
        callout.layoutSubtreeIfNeeded()
        #expect(callout.explanationLabel.maximumNumberOfLines == 0)
        #expect(callout.explanationLabel.frame.maxY <= height)
        #expect(callout.setupButton.frame.maxY < callout.explanationLabel.frame.minY)
        #expect(callout.explanationLabel.frame.width <= width)
        #expect(height >= CloudPortsVPNEmptyStateContent.height(width: 360, style: .defaultStyle))
    }

    @Test("Native keyboard and accessibility setup actions keep the source window")
    func calloutActionRouting() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let cell = CloudTreeCellView(frame: .zero)
        window.contentView = cell
        defer { window.contentView = nil }
        var routed: [NSWindow?] = []
        cell.configure(node: emptyPorts(link: .connected), machineActions: machineActions { routed.append($0) }, nodeActions: nodeActions(), showsCloudVPNWarning: true)
        let button = try #require(descendants(of: cell).compactMap { $0 as? CloudVPNSetupButton }.first)
        #expect(button.accessibilityPerformPress())
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: event)
        #expect(routed.count == 2)
        #expect(routed.allSatisfy { $0 === window })
    }

    @Test("The outline leaves Return to a focused native row control")
    func focusedControlOwnsReturn() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let outline = CloudTreeNSOutlineView(frame: .zero)
        let button = CloudVPNSetupButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), presentation: .text)
        window.contentView = outline
        outline.addSubview(button)
        defer { window.contentView = nil }
        var rowOpens = 0
        var setups = 0
        outline.onOpenSelection = { rowOpens += 1 }
        button.setup = { _ in setups += 1 }
        #expect(window.makeFirstResponder(button))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(!outline.performKeyEquivalent(with: event))
        button.keyDown(with: event)
        #expect(rowOpens == 0 && setups == 1)
    }

    @Test("Setup uses its dedicated pane and honors background focus without altering the machine workspace")
    func setupPanePreservesMachineWorkspace() throws {
        let suite = "CloudVPNSetupNavigation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = TabManager(autoWelcomeIfNeeded: false, createInitialWorkspace: false,
            settings: UserDefaultsSettingsClient(defaults: defaults), closeTabWarningDefaults: defaults)
        let machineWorkspace = manager.addWorkspace(eagerLoadTerminal: false, autoWelcomeIfNeeded: false, autoRefreshMetadata: false)
        let originalPanelIDs = Set(machineWorkspace.panels.keys)
        let originalFocus = machineWorkspace.focusedPanelId
        let navigation = CloudVPNSetupNavigation(coordinator: nil)
        let guideWorkspace = try #require(navigation.open(in: manager, focus: false))
        #expect(manager.selectedTabId == machineWorkspace.id)
        #expect(machineWorkspace.focusedPanelId == originalFocus)
        #expect(Set(machineWorkspace.panels.keys) == originalPanelIDs)
        #expect(guideWorkspace.id != machineWorkspace.id)
        #expect(navigation.open(in: manager)?.id == guideWorkspace.id)
        #expect(manager.selectedTabId == guideWorkspace.id)
        let guide = try #require(guideWorkspace.panels.values.compactMap { $0 as? CloudVPNSetupPanel }.first)
        #expect(guideWorkspace.focusedPanelId == guide.id)
        #expect(navigation.open(in: manager)?.id == guideWorkspace.id)
        #expect(manager.tabs.count == 2)
        #expect(guideWorkspace.panels.values.filter { $0 is CloudVPNSetupPanel }.count == 1)
        for workspace in manager.tabs { manager.closeWorkspace(workspace, recordHistory: false) }
    }

    private func emptyPorts(link: SurfaceLinkState) -> CloudTreeNode {
        CloudMachineSurfacePresentation.emptyPorts(info: SurfaceMachineInfo(
            id: .cloud("test"), name: "test", status: "running", image: "base", hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: link, linkError: link == .error ? "Link failed" : nil,
            cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        ))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func machineActions(setup: @escaping @MainActor (NSWindow?) -> Void = { _ in }) -> MachineRowActions {
        MachineRowActions(setupVPN: setup, openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, resizeCPU: { _, _ in },
            resizeMemory: { _, _ in }, promptUpgrade: {})
    }

    private func nodeActions() -> CloudTreeNodeActions {
        CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {})
    }
}
