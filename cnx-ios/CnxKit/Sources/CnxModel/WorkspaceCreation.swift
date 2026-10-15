import Foundation
import Observation

/// What a new workspace starts with.
public enum NewWorkspaceStart: Hashable, Sendable {
    /// The Mac's default: one terminal (cmux-tui `new-workspace`).
    case terminal
    /// An agent chat for a harness (`claude`, `codex`).
    case agent(String)
    /// A browser tab.
    case browser
}

/// One request to create a workspace.
public struct NewWorkspaceRequest: Hashable, Sendable {
    public var macID: String
    /// The working directory, or nil for the Mac's default (its home).
    public var directory: String?
    public var start: NewWorkspaceStart

    public init(macID: String, directory: String? = nil, start: NewWorkspaceStart = .terminal) {
        self.macID = macID
        self.directory = directory
        self.start = start
    }
}

/// The creation choices a backend supports on one Mac. The long-press menu
/// shows only these; everything else is hidden.
public struct WorkspaceCreationOptions: Hashable, Sendable {
    /// The phone may pick the working directory (recent directories).
    public var directories: Bool
    /// Agent harnesses that can be the first tab.
    public var agents: [String]
    /// A browser tab can be the first tab.
    public var browser: Bool
    /// Clone a git repository into the new workspace.
    public var cloneFromGit: Bool

    public init(directories: Bool = false, agents: [String] = [], browser: Bool = false, cloneFromGit: Bool = false) {
        self.directories = directories
        self.agents = agents
        self.browser = browser
        self.cloneFromGit = cloneFromGit
    }

    /// Only the default (a terminal in the Mac's home).
    public static let basic = WorkspaceCreationOptions()
}

/// A refusal the user sees ("Couldn't create a workspace on <Mac>: <message>").
public struct WorkspaceCreationError: Error, Hashable, Sendable, LocalizedError {
    public var message: String
    /// The message is written for the person (the phone's own words, or the Mac's
    /// reason it shows them too), so a toast shows it as is.
    public var isForPerson: Bool
    public init(_ message: String, isForPerson: Bool = false) {
        self.message = message
        self.isForPerson = isForPerson
    }
    public var errorDescription: String? { message }
}

/// A tab the phone can open in a workspace on its Mac.
public enum NewTabKind: Hashable, Sendable {
    case terminal
    /// An agent chat: the Mac's default agent, or a chosen harness and model.
    case agent(AgentChatStart)
    case browser

    /// The same kind, whatever agent or model it starts (for "is this kind offered").
    public var family: String {
        switch self {
        case .terminal: "terminal"
        case .agent: "agent"
        case .browser: "browser"
        }
    }
}

/// Where workspaces are really created: the mock store, or a Mac's daemon.
@MainActor
public protocol WorkspaceCreationBackend: AnyObject {
    /// Whether this backend can create on `macID` right now (online, linked).
    func canCreate(on macID: String) -> Bool
    /// What the long-press menu may offer on `macID`.
    func options(on macID: String) -> WorkspaceCreationOptions
    /// Creates the workspace. `placeholder` is the optimistic row already in
    /// the list; return the real workspace (the placeholder itself when the
    /// backend keeps its ids).
    func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace
    /// Whether this backend can rename and close workspaces on `macID` now.
    func canManage(on macID: String) -> Bool
    /// Renames a workspace on its Mac.
    func rename(_ workspace: Workspace, to title: String) async throws
    /// Closes a workspace on its Mac.
    func close(_ workspace: Workspace) async throws
    /// The tabs the phone may open in a workspace on `macID` now (none: the
    /// new-tab menu says why instead of making a tab the Mac never sees).
    func tabKinds(on macID: String) -> [NewTabKind]
    /// Tab kinds the phone shows but can't open on `macID` now, each with why (an
    /// older Mac without browser streaming, agents not connected yet).
    func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)]
    /// The Mac's agents and models for a new agent chat, with what a phone can't start.
    func agentCatalog(on macID: String) async throws -> AgentCatalog
    /// Opens a tab on the Mac and returns it once the Mac lists it.
    func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab
    /// Closes a tab on the Mac.
    func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws
}

extension WorkspaceCreationBackend {
    public func canManage(on macID: String) -> Bool { false }
    public func rename(_ workspace: Workspace, to title: String) async throws {
        throw WorkspaceCreationError("Renaming isn't available on this Mac")
    }
    public func close(_ workspace: Workspace) async throws {
        throw WorkspaceCreationError("Closing isn't available on this Mac")
    }
    public func tabKinds(on macID: String) -> [NewTabKind] { [] }
    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] { [] }
    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
}

/// Recent working directories per Mac, newest first, persisted.
public struct RecentDirectories: @unchecked Sendable {
    private let defaults: UserDefaults
    public static let limit = 5

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ macID: String) -> String { "cnx.workspaces.recentDirectories.\(macID)" }

    public func load(macID: String) -> [String] {
        defaults.stringArray(forKey: key(macID)) ?? []
    }

    public func note(_ directory: String, macID: String) {
        var list = load(macID: macID).filter { $0 != directory }
        list.insert(directory, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key(macID))
    }
}

/// Instant workspace creation: a tap inserts an optimistic row, the caller
/// pushes it right away, and the backend confirms (the row becomes the real
/// workspace, and the open screen follows it) or refuses (the row is
/// removed and `onFailure` reports it).
@MainActor
@Observable
public final class WorkspaceCreator {
    public enum Phase: Hashable, Sendable {
        case pending
        /// Created; the real workspace id.
        case created(String)
        case failed(String)
    }

    /// By placeholder id.
    public private(set) var phases: [String: Phase] = [:]
    public var backend: any WorkspaceCreationBackend
    /// The Mac the next workspace goes to, when it can take one.
    public private(set) var preferredMacID: String?
    /// A creation the Mac refused: the removed placeholder and the reason.
    @ObservationIgnored public var onFailure: (@MainActor (Workspace, String) -> Void)?
    /// A rename or close the Mac refused: the workspace, what failed
    /// ("Couldn't close cmux") and the reason. The change is already undone.
    @ObservationIgnored public var onManageFailure: (@MainActor (Workspace, String, String) -> Void)?
    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let recents: RecentDirectories
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    private static let preferredMacKey = "cnx.workspaces.newMac"

    public init(store: AppStore, backend: any WorkspaceCreationBackend, defaults: UserDefaults = .standard) {
        self.store = store
        self.backend = backend
        self.defaults = defaults
        recents = RecentDirectories(defaults: defaults)
        preferredMacID = defaults.string(forKey: Self.preferredMacKey)
    }

    /// The active team's Macs this backend can create on, in team order.
    public var availableMacs: [MacDevice] {
        (store.activeTeam?.macs ?? []).filter { $0.isOnline && backend.canCreate(on: $0.id) }
    }

    /// The preferred Mac when available, else the first available one.
    public var targetMac: MacDevice? {
        let macs = availableMacs
        return macs.first { $0.id == preferredMacID } ?? macs.first
    }

    /// Remembers the Mac new workspaces go to (the menu's Mac picker).
    public func prefer(macID: String) {
        guard preferredMacID != macID else { return }
        preferredMacID = macID
        defaults.set(macID, forKey: Self.preferredMacKey)
    }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        backend.options(on: macID)
    }

    /// Recent directories on a Mac: ones used for new workspaces from this
    /// phone, then the Mac's workspaces by activity. Empty when the backend
    /// cannot choose a directory.
    public func recentDirectories(on macID: String) -> [String] {
        guard options(on: macID).directories else { return [] }
        let used = recents.load(macID: macID)
        let seen = store.workspaces
            .filter { $0.macID == macID && !store.pendingWorkspaceIDs.contains($0.id) && !$0.directory.isEmpty }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map(\.directory)
        var result: [String] = []
        for directory in used + seen where !result.contains(directory) {
            result.append(directory)
        }
        return Array(result.prefix(RecentDirectories.limit))
    }

    /// The directory a plain tap uses: the last one used on that Mac, else
    /// its home. Nil when the Mac picks (the backend cannot choose).
    public func defaultDirectory(on macID: String) -> String? {
        guard options(on: macID).directories else { return nil }
        return recents.load(macID: macID).first ?? "~"
    }

    /// Starts creating a workspace and returns its optimistic placeholder,
    /// already in the list, to push. Nil when no Mac can take it or the
    /// start is not supported there.
    @discardableResult
    public func create(start: NewWorkspaceStart = .terminal, directory: String? = nil, macID: String? = nil) -> Workspace? {
        guard let mac = macID.flatMap({ id in availableMacs.first { $0.id == id } }) ?? targetMac else { return nil }
        let options = options(on: mac.id)
        switch start {
        case .terminal: break
        case .agent(let harness): guard options.agents.contains(harness) else { return nil }
        case .browser: guard options.browser else { return nil }
        }
        let dir = options.directories ? (directory ?? defaultDirectory(on: mac.id)) : nil
        let request = NewWorkspaceRequest(macID: mac.id, directory: dir, start: start)
        let placeholder = Self.placeholder(for: request, existing: store.workspaces.filter { $0.macID == mac.id }.map(\.title))
        store.insertPending(placeholder)
        store.requestFocusOnOpen(placeholder.id)
        phases[placeholder.id] = .pending
        if let dir { recents.note(dir, macID: mac.id) }
        tasks[placeholder.id] = Task { [weak self] in
            await self?.run(request, placeholder: placeholder)
        }
        return placeholder
    }

    /// Whether a workspace can be renamed or closed from this phone now:
    /// its Mac is online, the backend supports it, and it is not still
    /// being created.
    public func canManage(_ workspace: Workspace) -> Bool {
        guard !store.isPending(workspace.id),
              let mac = store.activeTeam?.macs.first(where: { $0.id == workspace.macID }), mac.isOnline else { return false }
        return backend.canManage(on: mac.id)
    }

    /// Renames at once; the old title comes back if the Mac refuses.
    public func rename(_ workspace: Workspace, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != workspace.title, canManage(workspace),
              let old = store.renameWorkspace(workspace.id, to: title) else { return }
        track(workspace.id) { [weak self] in
            do {
                try await self?.backend.rename(workspace, to: title)
            } catch {
                self?.store.renameWorkspace(workspace.id, to: old)
                self?.onManageFailure?(workspace, "Couldn't rename \(old)", Self.message(error))
            }
        }
    }

    /// Closes at once; the row comes back if the Mac refuses.
    public func close(_ workspace: Workspace) {
        guard canManage(workspace), let removed = store.removeWorkspace(workspace.id) else { return }
        track(workspace.id) { [weak self] in
            do {
                try await self?.backend.close(workspace)
            } catch {
                self?.store.restoreWorkspace(removed.workspace, at: removed.index)
                self?.onManageFailure?(workspace, "Couldn't close \(workspace.title)", Self.message(error))
            }
        }
    }

    private func track(_ id: String, _ work: @escaping @MainActor () async -> Void) {
        let key = "manage-\(id)-\(UUID().uuidString)"
        tasks[key] = Task { [weak self] in
            await work()
            self?.tasks[key] = nil
        }
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Waits for every creation in flight (tests and demos).
    public func settle() async {
        while let (id, task) = tasks.first {
            await task.value
            tasks[id] = nil
        }
    }

    private func run(_ request: NewWorkspaceRequest, placeholder: Workspace) async {
        defer { tasks[placeholder.id] = nil }
        do {
            let real = try await backend.create(request, placeholder: placeholder)
            store.resolvePending(placeholder.id, with: real)
            if let tab = Self.openingTab(of: real, for: request.start) {
                store.noteOpened(tabID: tab.id, in: real.id)
            }
            phases[placeholder.id] = .created(real.id)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            store.removePending(placeholder.id)
            phases[placeholder.id] = .failed(message)
            onFailure?(placeholder, message)
        }
    }

    /// The tab the new workspace opens on: the first one of the requested kind.
    static func openingTab(of workspace: Workspace, for start: NewWorkspaceStart) -> WorkspaceTab? {
        let match: (WorkspaceTab) -> Bool = switch start {
        case .terminal: { $0.kind == .terminal }
        case .agent(let harness): { $0.kind == .agent && $0.harness == harness }
        case .browser: { $0.kind == .browser }
        }
        return workspace.tabs.first(where: match) ?? workspace.tabs.first
    }

    /// The optimistic workspace: titled after its directory (or "New
    /// Workspace"), unique on its Mac, with the requested first tab.
    public static func placeholder(for request: NewWorkspaceRequest, existing titles: [String], now: Date = Date()) -> Workspace {
        let id = "new-\(UUID().uuidString.prefix(8).lowercased())"
        let directory = request.directory ?? "~"
        let base = Self.title(for: request.directory)
        let tabID = "\(id)-t1"
        let tab = switch request.start {
        case .terminal: WorkspaceTab(id: tabID, kind: .terminal, title: "zsh", subtitle: directory)
        case .agent(let harness):
            WorkspaceTab(id: tabID, kind: .agent, title: harness == "codex" ? "Codex" : harness == "claude" ? "Claude" : harness.capitalized,
                         subtitle: "New session", harness: harness)
        case .browser: WorkspaceTab(id: tabID, kind: .browser, title: "New Tab")
        }
        return Workspace(id: id, macID: request.macID, title: uniqueTitle(base, existing: titles), directory: directory,
                         tabs: [tab], lastActivityAt: now)
    }

    static func title(for directory: String?) -> String {
        guard let directory, directory != "~", directory != "/" else { return "New Workspace" }
        let last = (directory as NSString).lastPathComponent
        return last.isEmpty || last == "~" ? "New Workspace" : last
    }

    /// "cmux", then "cmux 2", "cmux 3", …
    public static func uniqueTitle(_ base: String, existing: [String]) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// No Mac is linked: nothing can be created, and a request says so (never a
/// made-up workspace).
@MainActor
public final class UnavailableWorkspaceCreationBackend: WorkspaceCreationBackend {
    public init() {}

    public func canCreate(on macID: String) -> Bool { false }

    public func options(on macID: String) -> WorkspaceCreationOptions { WorkspaceCreationOptions() }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        throw WorkspaceCreationError("Not connected to this Mac")
    }
}

#if DEBUG
/// Mock mode: every option, created after a short latency on an injected
/// clock. `failNext` makes the next creation fail (demo of the refusal path).
@MainActor
public final class MockWorkspaceCreationBackend: WorkspaceCreationBackend {
    public var failNext: String?
    private let clock: any Clock<Duration>
    private let latency: Duration

    public init(clock: any Clock<Duration> = ContinuousClock(), latency: Duration = .milliseconds(600)) {
        self.clock = clock
        self.latency = latency
    }

    public func canCreate(on macID: String) -> Bool { true }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        WorkspaceCreationOptions(directories: true, agents: ["claude", "codex"], browser: true, cloneFromGit: false)
    }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        try await settle()
        return placeholder
    }

    public func canManage(on macID: String) -> Bool { true }

    public func rename(_ workspace: Workspace, to title: String) async throws {
        try await settle()
    }

    public func close(_ workspace: Workspace) async throws {
        try await settle()
    }

    /// The kinds this mock Mac opens (all of them by default).
    public var kinds: [NewTabKind] = [.agentChat, .terminal, .browser]
    /// The kinds it shows but can't open, with why (an older Mac, agents not up).
    public var unavailable: [(kind: NewTabKind, reason: String)] = []

    public func tabKinds(on macID: String) -> [NewTabKind] { kinds }

    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] { unavailable }

    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        AgentCatalog(harnesses: [
            AgentHarnessChoice(id: "claude", name: "Claude Code", family: "claude", isDefault: true,
                               models: [AgentModelChoice(id: "opus", name: "Opus"), AgentModelChoice(id: "sonnet", name: "Sonnet")],
                               defaultModel: "opus"),
            AgentHarnessChoice(id: "codex", name: "Codex", family: "codex", unavailableReason: AgentCatalog.refusedReason),
        ])
    }

    /// Mock mode only: the tab exists in the mock store alone.
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        try await settle()
        let id = "t-\(UUID().uuidString.prefix(8).lowercased())"
        return switch kind {
        case .agent(let start):
            WorkspaceTab(id: id, kind: .agent, title: start.harness == "codex" ? "Codex" : "Claude", subtitle: "New session",
                         harness: start.harness ?? "claude")
        case .browser: WorkspaceTab(id: id, kind: .browser, title: "New Tab")
        case .terminal: WorkspaceTab(id: id, kind: .terminal, title: "zsh", subtitle: workspace.directory)
        }
    }

    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        try await settle()
    }

    private func settle() async throws {
        if latency > .zero { try await clock.sleep(for: latency) }
        if let message = failNext {
            failNext = nil
            throw WorkspaceCreationError(message)
        }
    }
}
#endif
