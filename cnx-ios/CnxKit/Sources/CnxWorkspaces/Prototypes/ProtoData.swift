#if DEBUG && os(iOS)
import CnxAgentChat
import CnxDesign
import CnxModel
import SwiftUI

/// Workspaces list design prototypes (`verify/workspaces-design-loop.md`).
/// DEBUG only, static data, shown by `-cnx-wsproto A|B|C` inside the real
/// Workspaces tab. Built on the real `Workspace` / `MacDevice` types so every
/// field a prototype shows exists in the live model (or is called out as
/// derived in the design doc).
enum ProtoData {
    static let now = Date()

    static let studio = MacDevice(id: "studio", name: "Mac Studio", isOnline: true, lastSeenAt: now)
    static let laptop = MacDevice(id: "mbp", name: "MacBook Pro", isOnline: false,
                                  lastSeenAt: now.addingTimeInterval(-2 * 3600))
    static let macs = [studio, laptop]

    private static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private static func claude(_ id: String, _ title: String) -> WorkspaceTab {
        WorkspaceTab(id: id, kind: .agent, title: title, harness: "claude")
    }

    private static func codex(_ id: String, _ title: String) -> WorkspaceTab {
        WorkspaceTab(id: id, kind: .agent, title: title, harness: "codex")
    }

    private static func term(_ id: String, _ title: String, _ dir: String) -> WorkspaceTab {
        WorkspaceTab(id: id, kind: .terminal, title: title, subtitle: dir)
    }

    private static func web(_ id: String, _ title: String, _ url: String) -> WorkspaceTab {
        WorkspaceTab(id: id, kind: .browser, title: title, url: URL(string: url))
    }

    static let workspaces: [Workspace] = [
        Workspace(id: "p-cmux", macID: "studio", title: "cmux", directory: "~/dev/cmux", branch: "feat-cnx-ios",
                  tabs: [claude("p-cmux-1", "Refactor transport layer"), term("p-cmux-2", "zsh", "~/dev/cmux"),
                         web("p-cmux-3", "localhost:5173", "http://localhost:5173")],
                  lastActivityAt: ago(1), needsAttention: true, colorHex: "#0A84FF", icon: "terminal"),
        Workspace(id: "p-web", macID: "studio", title: "cmux.com", directory: "~/dev/cmux.com", branch: "main",
                  tabs: [codex("p-web-1", "Fix pricing page layout"), term("p-web-2", "bun dev", "~/dev/cmux.com")],
                  lastActivityAt: ago(3), isWorking: true, colorHex: "#30D158", icon: "globe"),
        Workspace(id: "p-ios", macID: "studio", title: "ios-app", directory: "~/dev/cmux/cnx-ios",
                  branch: "feat-cnx-ios-wsdesign",
                  tabs: [claude("p-ios-1", "Redesign the workspaces list"), term("p-ios-2", "xcodebuild", "~/dev/cmux/cnx-ios")],
                  lastActivityAt: ago(6), isWorking: true, colorHex: "#BF5AF2", icon: "iphone"),
        Workspace(id: "p-ghostty", macID: "studio", title: "ghostty", directory: "~/dev/ghostty", branch: "sync-upstream",
                  tabs: [codex("p-gh-1", "Resolve merge conflicts"), term("p-gh-2", "zsh", "~/dev/ghostty")],
                  lastActivityAt: ago(25), needsAttention: true, colorHex: "#FF9F0A", icon: "👻"),
        Workspace(id: "p-fleet", macID: "studio", title: "fleet", directory: "~/dev/fleet", branch: "mini-recovery",
                  tabs: [claude("p-fl-1", "Audit runner labels"), term("p-fl-2", "ssh mini-cmux-3", "~/dev/fleet")],
                  lastActivityAt: ago(12), hasUnread: true, colorHex: "#64D2FF", icon: "server.rack"),
        Workspace(id: "p-docs", macID: "studio", title: "docs", directory: "~/dev/docs", branch: "main",
                  tabs: [term("p-docs-1", "mint dev", "~/dev/docs"), web("p-docs-2", "cmux docs", "http://localhost:3000")],
                  lastActivityAt: ago(130)),
        Workspace(id: "p-notes", macID: "studio", title: "notes", directory: "~/notes",
                  tabs: [term("p-notes-1", "nvim todo.md", "~/notes")],
                  lastActivityAt: ago(60 * 26)),
        Workspace(id: "p-zed", macID: "mbp", title: "zed", directory: "~/dev/zed", branch: "cmux-fork",
                  tabs: [claude("p-zed-1", "Port the tab strip"), term("p-zed-2", "cargo build", "~/dev/zed")],
                  lastActivityAt: ago(180), colorHex: "#5E5CE6", icon: "chevron.left.forwardslash.chevron.right"),
        Workspace(id: "p-blog", macID: "mbp", title: "blog", directory: "~/dev/blog", branch: "drafts",
                  tabs: [term("p-blog-1", "hugo server", "~/dev/blog")],
                  lastActivityAt: ago(60 * 30)),
        Workspace(id: "p-dot", macID: "mbp", title: "dotfiles", directory: "~/.dotfiles", branch: "main",
                  tabs: [term("p-dot-1", "zsh", "~/.dotfiles")],
                  lastActivityAt: ago(60 * 24 * 4)),
    ]

    static func mac(_ id: String) -> MacDevice? { macs.first { $0.id == id } }
}

/// What a row says about a workspace, highest priority first. Derived from
/// the live model: `needsAttention`, `isWorking`, `hasUnread` and the tabs.
enum ProtoStatus: Int, Comparable {
    case needsYou, working, done, idle, offline

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ ws: Workspace, online: Bool) {
        if !online { self = .offline }
        else if ws.needsAttention { self = .needsYou }
        else if ws.isWorking { self = .working }
        else if ws.hasUnread { self = .done }
        else { self = .idle }
    }
}

extension Workspace {
    /// The agent tab the status is about. Live: the tab whose surface is
    /// `blocked` / `working` in `AgentStates` (needs plumbing per tab); here,
    /// the first agent tab.
    var protoAgentTab: WorkspaceTab? { tabs.first { $0.kind == .agent } }

    var protoAgentName: String {
        switch protoAgentTab?.harness {
        case "claude": "Claude"
        case "codex": "Codex"
        case let other?: other.capitalized
        case nil: "Agent"
        }
    }

    /// The tab a tap opens: the one that needs you, else the last-used tab
    /// (TabMemory), else the Mac's active tab.
    var protoOpenTab: WorkspaceTab? {
        if needsAttention, let agent = protoAgentTab { return agent }
        return tabs.first
    }

    /// "feat-cnx-ios", or the directory without a branch.
    var protoWhere: String { branch ?? directory }
}

/// The prototype harness: one direction in the real Workspaces tab chrome.
public struct WorkspacesPrototype: View {
    public enum Direction: String, CaseIterable { case a = "A", b = "B", c = "C" }

    let direction: Direction
    let filterMacID: String?
    let open: @MainActor (Workspace) -> Void

    public init(direction: String, filterMacID: String? = nil, open: @escaping @MainActor (Workspace) -> Void) {
        self.direction = Direction(rawValue: direction.uppercased()) ?? .a
        self.filterMacID = filterMacID
        self.open = open
    }

    public var body: some View {
        switch direction {
        case .a: ProtoInbox(filterMacID: filterMacID, open: open)
        case .b: ProtoByMac(open: open)
        case .c: ProtoNow(filterMacID: filterMacID, open: open)
        }
    }

    /// `-cnx-wsproto <A|B|C>` and `-cnx-wsproto-mac <id>` from the launch arguments.
    public static var launchDirection: (String, String?)? {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let direction = value("-cnx-wsproto") else { return nil }
        return (direction, value("-cnx-wsproto-mac"))
    }
}

/// The pushed stand-in for a workspace: names the tab a tap would open.
public struct ProtoWorkspaceDestination: View {
    let workspace: Workspace

    public init(workspace: Workspace) { self.workspace = workspace }

    public var body: some View {
        let tab = workspace.protoOpenTab
        ContentUnavailableView {
            Label(tab?.title ?? workspace.title, systemImage: tab?.systemImage ?? "square.stack.3d.up")
        } description: {
            Text("Opens \(workspace.title)'s \(workspace.needsAttention ? "waiting" : "last") tab.")
        }
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
    }
}

// MARK: - Shared bits

private let theme = CnxTheme.standard

/// The leading status mark used by A and C: a 10 pt warning disc for
/// needs-you, a small spinner while working, a label dot for done/unread.
struct ProtoStatusMark: View {
    let status: ProtoStatus

    var body: some View {
        switch status {
        case .needsYou:
            Circle().fill(theme.colors.warning.color).frame(width: 10, height: 10)
        case .working:
            ProgressView().controlSize(.mini)
        case .done:
            Circle().fill(theme.colors.label.color).frame(width: 8, height: 8)
        case .idle, .offline:
            Color.clear.frame(width: 8, height: 8)
        }
    }
}

/// The status sentence: "Needs you · Claude — Refactor transport layer".
struct ProtoStatusLine: View {
    let workspace: Workspace
    let status: ProtoStatus
    var showMac: Bool = false

    var body: some View {
        Group {
            switch status {
            case .needsYou:
                Text("\(emphasis("\(workspace.protoAgentName) is waiting")) · \(workspace.protoAgentTab?.title ?? "")")
            case .working:
                HStack(spacing: 0) {
                    WorkingLabel("\(workspace.protoAgentName) is working", font: theme.type.rowSubtitle)
                    Text(" · \(workspace.protoAgentTab?.title ?? "")")
                }
            case .done:
                Text("\(emphasis("Done")) · \(workspace.protoAgentName): \(workspace.protoAgentTab?.title ?? "")")
            case .idle, .offline:
                Text(idleLine)
            }
        }
        .font(theme.type.rowSubtitle)
        .foregroundStyle(theme.colors.label2)
        .lineLimit(1)
    }

    private func emphasis(_ word: String) -> Text {
        Text(word).foregroundStyle(theme.colors.label).fontWeight(.semibold)
    }

    private var idleLine: String {
        var parts = [workspace.protoWhere]
        if showMac, let mac = ProtoData.mac(workspace.macID) { parts.append(mac.name) }
        return parts.joined(separator: " · ")
    }
}
#endif
