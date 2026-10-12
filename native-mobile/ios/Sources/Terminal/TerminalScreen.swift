import Observation
import SwiftUI

/// UI state shared between the UIKit terminal and its SwiftUI chrome.
@MainActor
@Observable
final class TerminalChromeState {
    var atBottom = true
    var scrollToBottom: (() -> Void)?
    /// The composer's real width; without it the hosting controller measures
    /// the composer at unlimited width and the text box never wraps.
    var width: CGFloat = 0
}

/// One terminal: Ghostty under floating glass controls, the composer docked
/// to the keyboard, files and diff one tap away.
struct TerminalScreen: View {
    let connection: HostConnection
    let tab: DaemonTab
    @State private var session: TerminalSession
    @State private var composer = ComposerModel()
    @State private var chrome = TerminalChromeState()
    @State private var showFiles = false
    @State private var showDiff = false
    @Environment(\.dismiss) private var dismiss

    init(connection: HostConnection, tab: DaemonTab) {
        self.connection = connection
        self.tab = tab
        _session = State(initialValue: connection.terminalSession(for: tab.surface))
    }

    private var liveTab: DaemonTab { connection.tab(surface: tab.surface) ?? tab }
    private var agent: DaemonAgent? { connection.agents[tab.surface] }

    var body: some View {
        TerminalHost(
            session: session,
            chrome: chrome,
            composer: ComposerHostContent(
                model: composer,
                session: session,
                chrome: chrome,
                services: connection.services,
                agentWorking: agent?.status == .working,
                placeholder: placeholder
            )
        )
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(Color(uiColor: Theme.terminalBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showFiles = true } label: { Image(systemName: "folder") }
                    .accessibilityLabel(String(localized: "Files"))
                    .accessibilityIdentifier("terminal.files")
                Button { showDiff = true } label: { Image(systemName: "plusminus") }
                    .accessibilityLabel(String(localized: "Changes"))
                    .accessibilityIdentifier("terminal.diff")
                    .disabled(liveTab.cwd == nil)
                moreMenu
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                if let services = connection.services {
                    SessionFilesScreen(cwd: liveTab.cwd, scrollbackText: { [connection, surface = tab.surface] in
                        await connection.scrollback(surface: surface)
                    }, services: services)
                }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDiff) {
            NavigationStack {
                if let services = connection.services, let cwd = liveTab.cwd {
                    DiffScreen(cwd: cwd, services: services)
                }
            }
            .presentationDragIndicator(.visible)
        }
        .onAppear { Task { await connection.acknowledge(surface: tab.surface) } }
        .onDisappear { session.detach() }
    }

    private var placeholder: String {
        switch agent?.status {
        case .blocked: String(localized: "Reply to \(agent?.agent ?? "agent")")
        case .working, .idle, .done: String(localized: "Message \(agent?.agent ?? "agent")")
        default: String(localized: "Type a command")
        }
    }

    private var titleView: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                if let agent { AgentStatusDot(status: agent.status) }
                Text(liveTab.displayTitle).font(.headline).lineLimit(1)
            }
            if let cwd = liveTab.shortCwd {
                Text(liveTab.gitBranch.map { "\(cwd) · \($0)" } ?? cwd)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: 220)
        .accessibilityElement(children: .combine)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = session.surfaceView.readAllText()
                Haptics.success()
            } label: { Label(String(localized: "Copy All Text"), systemImage: "doc.on.doc") }
            Button { chrome.scrollToBottom?() } label: { Label(String(localized: "Jump to Bottom"), systemImage: "arrow.down.to.line") }
            Button { session.sendKeys(["ctrl+l"]) } label: { Label(String(localized: "Clear Screen"), systemImage: "eraser") }
            Divider()
            Button(role: .destructive) {
                Task {
                    await connection.close(surface: tab.surface)
                    dismiss()
                }
            } label: { Label(String(localized: "Close Terminal"), systemImage: "xmark") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityIdentifier("terminal.more")
    }
}

/// The composer plus the jump-to-bottom button, hosted inside the UIKit
/// terminal controller (so the bottom scroll edge effect tracks it).
struct ComposerHostContent: View {
    let model: ComposerModel
    let session: TerminalSession
    let chrome: TerminalChromeState
    let services: ServiceClient?
    var agentWorking: Bool
    var placeholder: String

    var body: some View {
        VStack(spacing: 10) {
            if !chrome.atBottom && !session.isTUI {
                Button { chrome.scrollToBottom?() } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(String(localized: "Jump to bottom"))
                .accessibilityIdentifier("terminal.jumpToBottom")
            }
            ComposerBar(model: model, session: session, services: services, agentWorking: agentWorking, placeholder: placeholder)
        }
        .animation(.smooth(duration: 0.22), value: chrome.atBottom)
        .frame(width: chrome.width > 0 ? chrome.width : nil)
        .preferredColorScheme(.dark)
    }
}

/// Bridges `TerminalScrollController` into SwiftUI.
struct TerminalHost: UIViewControllerRepresentable {
    let session: TerminalSession
    let chrome: TerminalChromeState
    let composer: ComposerHostContent

    func makeUIViewController(context: Context) -> TerminalScrollController {
        let controller = TerminalScrollController(session: session)
        let host = UIHostingController(rootView: composer)
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        controller.install(composer: host)
        context.coordinator.host = host
        controller.onScrollStateChange = { [chrome] atBottom in
            if chrome.atBottom != atBottom { chrome.atBottom = atBottom }
        }
        chrome.scrollToBottom = { [weak controller] in controller?.scrollToBottom(animated: true) }
        controller.onWidthChange = { [chrome] width in
            if abs(chrome.width - width) > 0.5 { chrome.width = width }
        }
        return controller
    }

    func updateUIViewController(_ controller: TerminalScrollController, context: Context) {
        context.coordinator.host?.rootView = composer
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var host: UIHostingController<ComposerHostContent>?
    }
}

/// A small status dot: working (pulsing), blocked (attention), done.
struct AgentStatusDot: View {
    let status: AgentStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(status == .working && pulse ? 0.35 : 1)
            .animation(status == .working ? .easeInOut(duration: 0.9).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel(status.label)
    }

    private var color: Color {
        switch status {
        case .working: Theme.working
        case .blocked: Theme.attention
        case .done: Theme.success
        case .idle, .unknown: Color.secondary
        }
    }
}

extension AgentStatus {
    var label: String {
        switch self {
        case .working: String(localized: "Working")
        case .blocked: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        case .unknown: String(localized: "Unknown")
        }
    }
}
