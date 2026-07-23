import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Deterministic SplitMix64 PRNG. Every random draw in this file flows through
/// this generator, seeded from the test argument, so a failing case reproduces
/// exactly from the seed + step index in its failure message — no `Date()`, no
/// `SystemRandomNumberGenerator`, no wall-clock anywhere.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded model-based fuzz of the multiplexer's reconcile loop.
///
/// A tiny reference model (session name → stable id + ordered window ids +
/// killed-pending/detached marks) plays the remote tmux server; every step
/// mutates the model and/or drives a user action on the controller, re-applies
/// the model as the published workspace truth (the same
/// `applyMultiplexedWorkspaces` call the live view's change callback makes),
/// and then checks the full set of mirror/channel/workspace invariants.
///
/// The fixture is the sibling `RemoteTmuxMultiplexedSecondSessionTests` pattern:
/// a never-started shared control connection, a never-started view connection
/// registered in `multiplexedViewsByHost` (its init is side-effect free and all
/// its command sends no-op while unconnected), and explicit workspace data.
@MainActor
@Suite(.serialized)
struct RemoteTmuxMultiplexFuzzTests {
    private static let seeds: [UInt64] = [
        0x1, 0x2A, 0xBEEF, 0xC0FFEE, 0xDEAD10CC, 0xFAB1E5, 0x7209, 0x424242,
    ]

    @Test(arguments: seeds)
    func multiplexerSurvivesSeededSessionChurn(seed: UInt64) throws {
        let harness = try MultiplexFuzzHarness(seed: seed)
        defer { harness.finish() }
        try harness.bootstrap()
        for step in 1...250 {
            try harness.runStep(step)
        }
        // After all the churn, tearing every host down must free every mirror and
        // channel the run ever created — a retain cycle (a mirror closure capturing
        // self, an un-removed shared-stream observer) would keep them alive even
        // though the count invariants passed. Catches leaks the count checks can't.
        harness.assertNoLeaks()
    }

    // MARK: - Pure linked-view planner fuzz

    @Test(arguments: seeds)
    func linkedViewPlannerHoldsSafetyInvariants(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        func draw(_ bound: Int) -> Int { Int(rng.next() % UInt64(bound)) }

        let view = RemoteTmuxViewSession(ownerId: "fuzz-owner-\(String(seed, radix: 16))")

        for step in 0..<250 {
            let ctx = "seed=0x\(String(seed, radix: 16)) step=\(step)"
            var sessions: [RemoteTmuxViewSession.SessionRow] = []
            var windows: [RemoteTmuxLinkedWorkspaceModel.WindowRow] = []
            var nextWindow = 1
            var realWindowIds: [String] = []
            var realNames: [String] = []

            // Real (non-view) sessions with 1-3 windows each.
            let realCount = draw(5)
            for i in 0..<realCount {
                let name = "s\(i)"
                realNames.append(name)
                sessions.append(.init(name: name, isView: false, owner: "", version: nil))
                let windowCount = 1 + draw(3)
                for j in 0..<windowCount {
                    let id = "@\(nextWindow)"
                    nextWindow += 1
                    realWindowIds.append(id)
                    windows.append(.init(
                        sessionName: name, sessionId: "$\(i + 1)", windowId: id,
                        windowIndex: j, isActive: j == 0))
                }
            }
            // Occasionally a window linked into TWO real sessions (link-window
            // by hand on the host) — must still get exactly one home.
            if realNames.count >= 2, draw(4) == 0, let linked = realWindowIds.first {
                windows.append(.init(
                    sessionName: realNames[1], sessionId: "$2", windowId: linked,
                    windowIndex: 90, isActive: false))
            }
            // Decoy: a REAL session that merely carries the view name prefix
            // (untagged) — `isAnyView` must not exclude it.
            if draw(8) == 0 {
                let name = RemoteTmuxViewSession.namePrefix + "decoy"
                sessions.append(.init(name: name, isView: false, owner: "", version: nil))
                let id = "@\(nextWindow)"
                nextWindow += 1
                realWindowIds.append(id)
                windows.append(.init(
                    sessionName: name, sessionId: "$97", windowId: id, windowIndex: 0,
                    isActive: true))
            }
            // Decoy: tagged with @cmux_view but WITHOUT the reserved prefix — a
            // real session that copied the user option; also not a view.
            if draw(8) == 0 {
                let name = "tagged-but-real"
                sessions.append(.init(name: name, isView: true, owner: view.ownerId, version: 1))
                let id = "@\(nextWindow)"
                nextWindow += 1
                realWindowIds.append(id)
                windows.append(.init(
                    sessionName: name, sessionId: "$98", windowId: id, windowIndex: 0,
                    isActive: true))
            }

            // Our own live view session, usually present, with a placeholder
            // window and some linked copies of real windows.
            var viewWindowIds: [String] = []
            var placeholder: String?
            if draw(4) != 0 {
                sessions.append(.init(
                    name: view.sessionName, isView: true, owner: view.ownerId,
                    version: RemoteTmuxViewSession.formatVersion))
                let ph = "@\(nextWindow)"
                nextWindow += 1
                viewWindowIds.append(ph)
                windows.append(.init(
                    sessionName: view.sessionName, sessionId: "$99", windowId: ph,
                    windowIndex: 0, isActive: false))
                if draw(4) != 0 { placeholder = ph }
                for (offset, id) in realWindowIds.enumerated() where draw(2) == 0 {
                    viewWindowIds.append(id)
                    windows.append(.init(
                        sessionName: view.sessionName, sessionId: "$99", windowId: id,
                        windowIndex: offset + 1, isActive: false))
                }
            }
            // A stale view of OUR owner (old format) and a FOREIGN owner's view.
            if draw(4) == 0 {
                sessions.append(.init(
                    name: RemoteTmuxViewSession.namePrefix + "stale-old", isView: true,
                    owner: view.ownerId, version: 0))
            }
            if draw(4) == 0 {
                let name = RemoteTmuxViewSession.namePrefix + "foreign"
                sessions.append(.init(name: name, isView: true, owner: "other-owner", version: 1))
                let id = "@\(nextWindow)"
                nextWindow += 1
                windows.append(.init(
                    sessionName: name, sessionId: "$96", windowId: id, windowIndex: 0,
                    isActive: false))
            }

            // Ownership: a random subset of the view's contents, sometimes plus
            // ids that are NOT in the view (stale bookkeeping must stay safe).
            var owned: Set<String> = []
            for id in viewWindowIds where draw(2) == 0 { owned.insert(id) }
            if draw(4) == 0 { owned.insert("@777777") }
            if draw(4) == 0, let real = realWindowIds.last { owned.insert(real) }

            let snapshot = RemoteTmuxLinkedViewPlan.Snapshot(
                sessions: sessions,
                windows: windows,
                cmuxOwnedWindowIds: owned,
                placeholderWindowId: placeholder)
            let plan = RemoteTmuxLinkedViewPlan.plan(view: view, snapshot: snapshot)

            // Determinism: the same snapshot yields the same plan.
            let replay = RemoteTmuxLinkedViewPlan.plan(view: view, snapshot: snapshot)
            #expect(plan == replay, "plan must be deterministic \(ctx)")

            let excluded = Set(
                sessions.filter { RemoteTmuxViewSession.isAnyView($0) }.map(\.name))
            for action in plan.reconcileActions {
                switch action {
                case .unlinkFromView(let id):
                    #expect(
                        id != snapshot.placeholderWindowId,
                        "placeholder must never be unlinked \(ctx)")
                    #expect(
                        snapshot.cmuxOwnedWindowIds.contains(id),
                        "only cmux-owned windows may be unlinked, got \(id) \(ctx)")
                    #expect(
                        viewWindowIds.contains(id),
                        "unlink target must be present in the view, got \(id) \(ctx)")
                    #expect(
                        !plan.needsViewCreate,
                        "a view about to be created has nothing to unlink \(ctx)")
                case .link(let id):
                    #expect(
                        windows.contains { $0.windowId == id && !excluded.contains($0.sessionName) },
                        "link target must have a real home session, got \(id) \(ctx)")
                }
            }
            for workspace in plan.workspaces {
                #expect(
                    !excluded.contains(workspace.sessionName),
                    "workspace \(workspace.sessionName) must be a real session \(ctx)")
            }
            #expect(
                !plan.staleViewsToKill.contains(view.sessionName),
                "current view must never be GC'd \(ctx)")
            for stale in plan.staleViewsToKill {
                let row = sessions.first { $0.name == stale }
                #expect(
                    row.map { view.isOwnStaleView($0) } == true,
                    "only our own stale views may be killed, got \(stale) \(ctx)")
            }
            let hasRealSession = sessions.contains { !RemoteTmuxViewSession.isAnyView($0) }
            #expect(
                plan.needsBootstrapSession == !hasRealSession,
                "bootstrap keyed off the session list \(ctx)")
        }
    }

    /// A session row with our name and our owner, but not the version we stamp, must not be
    /// offered for reaping — the live control client is attached to that session, so killing it
    /// takes the whole host's mirror down.
    ///
    /// This does not need a format bump to happen: an ownership `set-option` that never landed
    /// leaves the version option unset, which is exactly what these two rows look like. The
    /// classification cannot rule the row out (it is "one of our views that is not the current
    /// one" by construction), so the plan filters the name.
    @Test(arguments: [0, nil] as [Int?])
    func planNeverOffersTheLiveViewForReaping(version: Int?) {
        let view = RemoteTmuxViewSession(ownerId: "own-name-wrong-version")
        let ownRow = RemoteTmuxViewSession.SessionRow(
            name: view.sessionName, isView: true, owner: view.ownerId, version: version)
        // The premise: the classification alone DOES match this row, which is why the filter
        // has to exist rather than being documented as impossible.
        #expect(view.isOwnStaleView(ownRow))

        let staleOther = RemoteTmuxViewSession.SessionRow(
            name: RemoteTmuxViewSession.namePrefix + "v0-old-owner-name", isView: true,
            owner: view.ownerId, version: 0)
        let plan = RemoteTmuxLinkedViewPlan.plan(
            view: view,
            snapshot: .init(
                sessions: [
                    ownRow,
                    staleOther,
                    .init(name: "work", isView: false, owner: "", version: nil),
                ],
                windows: [
                    .init(sessionName: "work", sessionId: "$1", windowId: "@1", windowIndex: 0,
                          isActive: true),
                ],
                cmuxOwnedWindowIds: [],
                placeholderWindowId: nil))
        #expect(!plan.staleViewsToKill.contains(view.sessionName))
        // The other stale view is still collected, so the filter is about our own name and not
        // about turning the reap off.
        #expect(plan.staleViewsToKill == [staleOther.name])
    }

    /// The view session name carries the format version, which is what makes a bump take
    /// effect: the stream attaches with `new-session -A -s <name>` and would otherwise reuse an
    /// incompatible view and stamp the new version onto it. A different name instead falls
    /// straight into the stale-view reap.
    @Test func theViewNameCarriesTheFormatVersion() {
        let view = RemoteTmuxViewSession(ownerId: "version-in-name")
        let versionSegment = "v\(RemoteTmuxViewSession.formatVersion)-"
        #expect(view.sessionName.hasPrefix(RemoteTmuxViewSession.namePrefix + versionSegment))

        let previousFormat = RemoteTmuxViewSession.SessionRow(
            name: RemoteTmuxViewSession.namePrefix + "v0-version-in-name-"
                + RemoteTmuxViewSession.ownerHash("version-in-name"),
            isView: true, owner: view.ownerId, version: 0)
        #expect(previousFormat.name != view.sessionName)
        #expect(!view.isOwnView(previousFormat))
        #expect(view.isOwnStaleView(previousFormat))
        let plan = RemoteTmuxLinkedViewPlan.plan(
            view: view,
            snapshot: .init(
                sessions: [previousFormat, .init(name: "work", isView: false, owner: "", version: nil)],
                windows: [
                    .init(sessionName: "work", sessionId: "$1", windowId: "@1", windowIndex: 0,
                          isActive: true),
                ],
                cmuxOwnedWindowIds: [],
                placeholderWindowId: nil))
        #expect(plan.staleViewsToKill == [previousFormat.name])
    }

    /// The placeholder is the first UNLINKED row, not the first row.
    ///
    /// Measured on tmux 3.7: `link-window -b` inserts before its target and `base-index`
    /// differs between hosts, so the lowest-index window in the view can be a linked copy.
    /// Taking the first row protected that copy from unlinking and left the real placeholder
    /// unprotected, so reconcile could unlink the one window the view cannot lose.
    @Test func theBringupTakesTheUnlinkedRowAsThePlaceholder() {
        let linkedFirst = RemoteTmuxViewConnection.readBringupRows([
            "@41 1", "@7 0", "@42 1",
        ])
        #expect(linkedFirst.placeholder == "@7")
        #expect(linkedFirst.adopted == ["@41", "@42"])

        // The ordinary shape, where the placeholder does sit first, must be unchanged.
        let placeholderFirst = RemoteTmuxViewConnection.readBringupRows([
            "@7 0", "@41 1", "@42 1",
        ])
        #expect(placeholderFirst.placeholder == "@7")
        #expect(placeholderFirst.adopted == ["@41", "@42"])

        // Every row linked (no placeholder to find) falls back to the first row, which keeps
        // one window protected rather than leaving the view with nothing it may not unlink.
        let allLinked = RemoteTmuxViewConnection.readBringupRows(["@41 1", "@42 1"])
        #expect(allLinked.placeholder == "@41")
        #expect(allLinked.adopted == ["@42"])

        // A reply with no rows leaves nothing adopted rather than inventing a placeholder.
        let empty = RemoteTmuxViewConnection.readBringupRows([])
        #expect(empty.placeholder == nil)
        #expect(empty.adopted.isEmpty)
    }
}

/// One session in the reference model: its rename-stable id, ordered windows,
/// id-publication delay, and whether the user has closed or detached it.
private struct FuzzModelSession {
    var id: Int
    var windows: [Int]
    var revealIdAtStep: Int
    var killedPending = false
    var detached = false

    func publishedId(at step: Int) -> Int? { step >= revealIdAtStep ? id : nil }
}

@MainActor
private final class FuzzHostModel {
    let host: RemoteTmuxHost
    let shared: RemoteTmuxControlConnection
    var truth: [String: FuzzModelSession] = [:]
    var removedNames: Set<String> = []
    var usedNames: Set<String> = []
    var workspaceBySessionId: [Int: Workspace] = [:]
    var expectedSelection: (sessionId: Int, shouldSelect: Bool)?
    var hostStopped = false
    var detachLeftovers = 0
    var nextSessionId: Int
    var nextWindowId: Int
    var nextName = 1

    init(index: Int, controller: RemoteTmuxController) {
        host = RemoteTmuxHost(destination: "user@fuzz-single-channel-\(index)")
        shared = RemoteTmuxControlConnection(host: host, sessionName: "cmux-view-fuzz-\(index)")
        nextSessionId = index * 10_000 + 1
        nextWindowId = index * 100_000 + 1
        controller.multiplexedViewsByHost[host.connectionHash] = RemoteTmuxViewConnection(
            host: host, ownerId: "fuzz-owner-\(index)")
    }

    var liveNames: [String] {
        truth.filter { !$0.value.killedPending && !$0.value.detached }.keys.sorted()
    }
}

/// Weak handle to a mirror/channel created during the run, so end-of-run teardown
/// can prove they actually deallocate (no retain cycle).
@MainActor
private final class LeakProbe {
    let sessionName: String
    weak var mirror: RemoteTmuxSessionMirror?
    weak var channel: RemoteTmuxSessionChannel?
    init(sessionName: String) { self.sessionName = sessionName }
}

/// Drives one seeded fuzz run: owns the controller/manager fixture, two host models
/// with overlapping names, and the invariant checks.
@MainActor
private final class MultiplexFuzzHarness {
    private let controller = RemoteTmuxController()
    private let manager = TabManager()
    private let appDelegate: AppDelegate
    private let windowId: UUID
    private let initialLocalCount: Int
    private var rng: SplitMix64
    private var hosts: [FuzzHostModel] = []
    /// Weak probes for every distinct mirror seen. Drives ``assertNoLeaks``.
    private var leakProbes: [LeakProbe] = []
    /// Probes keyed by the mirror's object identity, used ONLY to dedup a mirror that
    /// is still alive at the same address. A recycled address whose prior mirror has
    /// deallocated gets a fresh probe, so a new mirror born at a reused address is
    /// never silently skipped by ``assertNoLeaks``.
    private var leakProbeByMirrorID: [ObjectIdentifier: LeakProbe] = [:]

    private let seedLabel: String
    private var step = 0
    private var ctx: String { "\(seedLabel) step=\(step)" }

    init(seed: UInt64) throws {
        rng = SplitMix64(seed: seed)
        seedLabel = "seed=0x\(String(seed, radix: 16))"
        _ = NSApplication.shared
        appDelegate = try #require(
            AppDelegate.shared, "fuzz needs the test-host app delegate")
        windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        initialLocalCount = manager.tabs.count
        hosts = [
            FuzzHostModel(index: 1, controller: controller),
            FuzzHostModel(index: 2, controller: controller),
        ]
    }

    func finish() {
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
    }

    func bootstrap() throws {
        step = 0
        for host in hosts {
            addSession(on: host)
            apply(host)
        }
        try assertInvariants()
    }

    func runStep(_ index: Int) throws {
        step = index
        guard let host = pick(hosts.filter { !$0.hostStopped }) else { return }
        switch draw(20) {
        case 0, 1: addSession(on: host)
        case 2: reuseRemovedName(on: host)
        case 3: removeSession(on: host)
        case 4: addWindow(on: host)
        case 5: removeWindow(on: host)
        case 6: shuffleWindows(on: host)
        case 7: renameSession(on: host)
        case 8: renameOntoUsedName(on: host)
        case 9: twoSessionNameSwap(on: host)
        case 10: recreateKilledPendingNameSameSnapshot(on: host)
        case 11: renameLiveOntoKilledPendingName(on: host)
        case 12: apply(host)
        case 13: try closeMirrorWorkspace(on: host)
        case 14: confirmPendingKill(on: host)
        case 15: try detachKeptOpen(on: host)
        case 16: try injectPendingSelect(on: host, shouldSelect: true)
        case 17: try injectPendingSelect(on: host, shouldSelect: false)
        case 18: walkAcrossSessions(on: host)
        default: try claimNewWorkspace(on: host)
        }
        // Apply EVERY live host, not just the mutated one: id publication is
        // step-indexed, and a revealed id only reaches a channel through an
        // apply — mirroring production, where each host's view reconciles on
        // its own cadence regardless of which host changed.
        for liveHost in hosts where !liveHost.hostStopped { apply(liveHost) }
        try assertInvariants()
    }

    // MARK: - Random draws

    private func draw(_ bound: Int) -> Int { Int(rng.next() % UInt64(bound)) }

    private func pick<T>(_ candidates: [T]) -> T? {
        candidates.isEmpty ? nil : candidates[draw(candidates.count)]
    }

    // MARK: - Model steps

    private func addSession(on host: FuzzHostModel) {
        guard host.truth.count < 8 else { return }
        let name = "s\(host.nextName)"
        host.nextName += 1
        addSession(on: host, named: name)
    }

    private func reuseRemovedName(on host: FuzzHostModel) {
        guard host.truth.count < 8 else { return }
        let candidates = host.removedNames.filter { host.truth[$0] == nil }.sorted()
        guard let name = pick(candidates) else { addSession(on: host); return }
        addSession(on: host, named: name)
    }

    @discardableResult
    private func addSession(on host: FuzzHostModel, named name: String) -> Int {
        var windows: [Int] = []
        for _ in 0..<(1 + draw(3)) {
            windows.append(host.nextWindowId)
            host.nextWindowId += 1
        }
        let id = host.nextSessionId
        host.nextSessionId += 1
        let revealDelay = draw(4) == 0 ? 1 + draw(4) : 0
        host.truth[name] = FuzzModelSession(id: id, windows: windows, revealIdAtStep: step + revealDelay)
        host.usedNames.insert(name)
        return id
    }

    private func removeSession(on host: FuzzHostModel) {
        guard let name = pick(host.truth.keys.sorted()) else { return }
        host.truth.removeValue(forKey: name)
        host.removedNames.insert(name)
    }

    private func addWindow(on host: FuzzHostModel) {
        let candidates = host.liveNames.filter { (host.truth[$0]?.windows.count ?? 0) < 5 }
        guard let name = pick(candidates) else { return }
        host.truth[name]!.windows.append(host.nextWindowId)
        host.nextWindowId += 1
    }

    private func removeWindow(on host: FuzzHostModel) {
        let candidates = host.liveNames.filter { (host.truth[$0]?.windows.count ?? 0) >= 2 }
        guard let name = pick(candidates) else { return }
        host.truth[name]!.windows.remove(at: draw(host.truth[name]!.windows.count))
    }

    private func shuffleWindows(on host: FuzzHostModel) {
        let candidates = host.liveNames.filter { (host.truth[$0]?.windows.count ?? 0) >= 2 }
        guard let name = pick(candidates) else { return }
        host.truth[name]!.windows.shuffle(using: &rng)
    }

    private func renameSession(on host: FuzzHostModel) {
        guard let oldName = pick(host.liveNames) else { return }
        let newName = "r\(host.nextName)"
        host.nextName += 1
        rename(on: host, oldName: oldName, newName: newName)
    }

    private func renameOntoUsedName(on host: FuzzHostModel) {
        guard let oldName = pick(host.liveNames) else { return }
        let candidates = host.usedNames.filter { host.truth[$0] == nil }.sorted()
        guard let newName = pick(candidates) else { renameSession(on: host); return }
        rename(on: host, oldName: oldName, newName: newName)
    }

    private func rename(on host: FuzzHostModel, oldName: String, newName: String) {
        guard oldName != newName, let session = host.truth.removeValue(forKey: oldName) else { return }
        host.truth[newName] = session
        host.usedNames.insert(newName)
        host.removedNames.insert(oldName)
    }

    private func twoSessionNameSwap(on host: FuzzHostModel) {
        let live = host.liveNames
        guard live.count >= 2 else { return }
        let first = live[draw(live.count)]
        let rest = live.filter { $0 != first }
        guard let second = pick(rest), let a = host.truth[first], let b = host.truth[second] else { return }
        host.truth[first] = b
        host.truth[second] = a
    }

    private func idKnownPendingKillNames(on host: FuzzHostModel) -> [String] {
        let refs = controller.multiplexIntentsByHost[host.host.connectionHash]?.pendingKills ?? []
        return refs.compactMap { $0.id == nil ? nil : $0.name }.sorted()
    }

    private func recreateKilledPendingNameSameSnapshot(on host: FuzzHostModel) {
        guard host.truth.count < 8 else { return }
        let idKnownKilled = Set(idKnownPendingKillNames(on: host))
        let candidates = host.truth
            .filter { $0.value.killedPending && idKnownKilled.contains($0.key) }
            .keys
            .sorted()
        guard let name = pick(candidates) else { return }
        host.truth.removeValue(forKey: name)
        host.removedNames.insert(name)
        _ = addSession(on: host, named: name)
    }

    private func renameLiveOntoKilledPendingName(on host: FuzzHostModel) {
        let idKnownKilled = Set(idKnownPendingKillNames(on: host))
        let killed = host.truth
            .filter { $0.value.killedPending && idKnownKilled.contains($0.key) }
            .keys
            .sorted()
        let live = host.liveNames
        guard let targetName = pick(killed), let liveName = pick(live.filter({ $0 != targetName })) else { return }
        host.truth.removeValue(forKey: targetName)
        host.removedNames.insert(targetName)
        rename(on: host, oldName: liveName, newName: targetName)
    }

    private func closeMirrorWorkspace(on host: FuzzHostModel) throws {
        guard let name = pick(host.liveNames) else { return }
        let mirror = try #require(
            controller.sessionMirror(host: host.host, sessionName: name),
            "live session \(name) must have a mirror \(ctx)")
        let workspace = try #require(mirror.mirroredWorkspace, "mirror workspace \(ctx)")
        controller.handleWorkspaceClosed(workspaceId: workspace.id)
        manager.closeWorkspace(workspace, recordHistory: false)
        host.truth[name]!.killedPending = true
    }

    private func confirmPendingKill(on host: FuzzHostModel) {
        let candidates = host.truth.filter { $0.value.killedPending }.keys.sorted()
        guard let name = pick(candidates) else { return }
        host.truth.removeValue(forKey: name)
        host.removedNames.insert(name)
    }

    private func detachKeptOpen(on host: FuzzHostModel) throws {
        guard let name = pick(host.liveNames) else { return }
        let mirror = try #require(
            controller.sessionMirror(host: host.host, sessionName: name),
            "live session \(name) must have a mirror \(ctx)")
        let workspace = try #require(mirror.mirroredWorkspace, "mirror workspace \(ctx)")
        controller.detachMirrorWorkspaceKeptOpenLocally(workspaceId: workspace.id)
        host.truth[name]!.detached = true
        host.detachLeftovers += 1
    }

    private func injectPendingSelect(on host: FuzzHostModel, shouldSelect: Bool) throws {
        guard host.truth.count < 8 else { return }
        let origin = try #require(manager.selectedTab?.id, "manager has a selected tab \(ctx)")
        if !shouldSelect {
            guard let other = manager.tabs.first(where: { $0.id != origin }) else { return }
            manager.selectWorkspace(other)
        }
        let name = "sel\(host.nextName)"
        host.nextName += 1
        let id = addSession(on: host, named: name)
        host.truth[name]!.revealIdAtStep = step
        var intents = controller.multiplexIntentsByHost[host.host.connectionHash] ?? .init()
        intents.pendingSelect = .init(sessionName: name, originatingTabId: origin)
        controller.storeMultiplexIntents(intents, hostHash: host.host.connectionHash)
        host.expectedSelection = (sessionId: id, shouldSelect: shouldSelect)
    }

    /// Walk across the host's linked sessions the way a user tabs between them:
    /// select a random live mirror workspace and assert the selection lands on it.
    /// Exercises the cmux-driven select path alongside the tmux-driven churn.
    private func walkAcrossSessions(on host: FuzzHostModel) {
        let mirrorWorkspaces = controller.sessionMirrors.values
            .filter { $0.host.connectionHash == host.host.connectionHash }
            .compactMap(\.mirroredWorkspace)
        guard let target = pick(mirrorWorkspaces) else { return }
        manager.selectWorkspace(target)
        #expect(
            manager.selectedTab?.id == target.id,
            "walking to a live mirror selects its workspace \(ctx)")
    }

    private func claimNewWorkspace(on host: FuzzHostModel) throws {
        guard let name = pick(host.liveNames) else { return }
        let mirror = try #require(
            controller.sessionMirror(host: host.host, sessionName: name),
            "live session \(name) must have a mirror \(ctx)")
        let workspace = try #require(mirror.mirroredWorkspace, "mirror workspace \(ctx)")
        manager.selectWorkspace(workspace)
        let tabsBefore = manager.tabs.count
        #expect(
            controller.handleNewWorkspaceRequested(in: manager),
            "new-workspace on a mirror must be claimed \(ctx)")
        #expect(
            manager.tabs.count == tabsBefore,
            "a claimed new-workspace must not create a local workspace \(ctx)")
    }

    // MARK: - Apply + invariants

    private func apply(_ host: FuzzHostModel) {
        guard !host.hostStopped else { return }
        guard controller.multiplexedViewsByHost[host.host.connectionHash] != nil else {
            host.hostStopped = true
            return
        }
        let workspaces = host.truth.keys.sorted().map { name -> RemoteTmuxLinkedWorkspaceModel.Workspace in
            let session = host.truth[name]!
            return .init(
                sessionName: name,
                windowIds: session.windows.map { "@\($0)" },
                activeWindowId: session.windows.first.map { "@\($0)" },
                sessionId: session.publishedId(at: step))
        }
        controller.applyMultiplexedWorkspaces(
            host: host.host, manager: manager, workspaces: workspaces, shared: host.shared)
        if controller.multiplexedViewsByHost[host.host.connectionHash] == nil {
            host.hostStopped = true
        }
        trackMirrorsForLeakCheck()
    }

    /// Records a weak probe for each new mirror so ``assertNoLeaks`` can confirm it
    /// deallocates once its host is torn down.
    private func trackMirrorsForLeakCheck() {
        for mirror in controller.sessionMirrors.values {
            let mirrorID = ObjectIdentifier(mirror)
            // Skip only if the SAME live object is already probed; a reused address
            // whose prior mirror deallocated falls through and gets a fresh probe.
            if leakProbeByMirrorID[mirrorID]?.mirror === mirror { continue }
            let probe = LeakProbe(sessionName: mirror.sessionName)
            probe.mirror = mirror
            probe.channel = mirror.connection as? RemoteTmuxSessionChannel
            leakProbes.append(probe)
            leakProbeByMirrorID[mirrorID] = probe
        }
    }

    /// Tears every host down and asserts every mirror/channel the run created has
    /// deallocated. A survivor is a retain cycle — the count invariants can't catch
    /// it because the object is already out of `sessionMirrors`/`channelsByHostSession`.
    func assertNoLeaks() {
        for host in hosts { _ = controller.stopMultiplexedHost(host: host.host) }
        // Let any run-loop-coalesced release (deferred Tasks, observer teardown) run.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(controller.sessionMirrors.isEmpty, "all mirrors removed after teardown \(seedLabel)")
        #expect(controller.channelsByHostSession.isEmpty, "all channels removed after teardown \(seedLabel)")
        for probe in leakProbes {
            #expect(probe.mirror == nil, "mirror \(probe.sessionName) leaked (retain cycle) \(seedLabel)")
            #expect(probe.channel == nil, "channel \(probe.sessionName) leaked (retain cycle) \(seedLabel)")
        }
    }

    private func assertInvariants() throws {
        for host in hosts {
            if host.hostStopped {
                #expect(controller.multiplexedViewsByHost[host.host.connectionHash] == nil, "stopped host view removed \(ctx)")
                #expect(!controller.sessionMirrors.values.contains { $0.host.connectionHash == host.host.connectionHash }, "stopped host mirrors removed \(ctx)")
                #expect(controller.multiplexIntentsByHost[host.host.connectionHash] == nil, "stopped host intents cleared \(ctx)")
                continue
            }

            let live = Set(host.liveNames)
            let mirrors = controller.sessionMirrors.filter { _, mirror in
                mirror.host.connectionHash == host.host.connectionHash
            }
            #expect(
                Set(mirrors.values.map(\.sessionName)) == live,
                "mirror set must equal live sessions \(ctx): host=\(host.host.destination) mirrors=\(mirrors.values.map(\.sessionName).sorted()) live=\(live.sorted())")
            #expect(mirrors.count == live.count, "one mirror per live session \(ctx)")

            var liveWorkspaceObjects: Set<ObjectIdentifier> = []
            for mirror in mirrors.values {
                let name = mirror.sessionName
                let channel = try #require(
                    mirror.connection as? RemoteTmuxSessionChannel,
                    "mirror \(name) must use a session channel \(ctx)")
                #expect(channel.underlying === host.shared, "channel scopes the correct host stream \(ctx)")
                let workspace = try #require(
                    mirror.mirroredWorkspace, "mirror \(name) must keep its workspace \(ctx)")
                #expect(manager.tabs.contains(where: { $0 === workspace }), "workspace live \(ctx)")
                #expect(workspace.title == name, "workspace title tracks session \(ctx)")
                let liveWorkspaceInserted = liveWorkspaceObjects.insert(ObjectIdentifier(workspace)).inserted
                #expect(liveWorkspaceInserted, "live sessions do not share a workspace object \(ctx)")
                let key = RemoteTmuxController.connectionKey(host: host.host, sessionName: name)
                #expect(controller.sessionMirrors[key] === mirror, "mirror key current \(ctx)")
                #expect(controller.channelsByHostSession[key] === channel, "channel key current \(ctx)")

                let session = try #require(host.truth[name], "mirror \(name) exists in truth \(ctx)")
                #expect(channel.windowIds == session.windows, "channel window order follows id \(session.id) \(ctx)")
                if let publishedId = session.publishedId(at: step) {
                    #expect(channel.sessionId == publishedId, "channel keeps known session id \(ctx)")
                    if let previous = host.workspaceBySessionId[session.id] {
                        #expect(previous === workspace, "session id \(session.id) kept workspace identity \(ctx)")
                    } else {
                        #expect(
                            !host.workspaceBySessionId.values.contains { $0 === workspace },
                            "new session id \(session.id) got a fresh workspace object \(ctx)")
                        host.workspaceBySessionId[session.id] = workspace
                    }
                }
            }

            for (name, session) in host.truth where session.killedPending || session.detached {
                #expect(
                    !mirrors.values.contains { $0.sessionName == name },
                    "no mirror for excluded session \(name) \(ctx)")
            }

            let hostChannelCount = controller.channelsByHostSession.filter { key, _ in
                key.hasPrefix(host.host.connectionHash + "\u{1}")
            }.count
            #expect(hostChannelCount == live.count, "no cross-host channel bleed \(ctx)")

            if let expected = host.expectedSelection {
                let selectedId = manager.selectedTab?.id
                let workspace = mirrors.values.first { mirror in
                    let name = mirror.sessionName
                    return host.truth[name]?.id == expected.sessionId
                }?.mirroredWorkspace
                if expected.shouldSelect {
                    #expect(selectedId == workspace?.id, "pending select chose created workspace \(ctx)")
                } else {
                    #expect(selectedId != workspace?.id, "pending select did not steal focus after origin changed \(ctx)")
                }
                host.expectedSelection = nil
            }
        }

        let liveTotal = hosts.filter { !$0.hostStopped }.reduce(0) { $0 + $1.liveNames.count }
        let detachLeftovers = hosts.reduce(0) { $0 + $1.detachLeftovers }
        #expect(
            manager.tabs.count == initialLocalCount + liveTotal + detachLeftovers,
            "workspace count bounded \(ctx): tabs=\(manager.tabs.count) expected=\(initialLocalCount + liveTotal + detachLeftovers)")
    }
}
