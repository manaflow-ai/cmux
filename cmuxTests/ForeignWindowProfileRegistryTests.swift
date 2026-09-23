import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
private final class FakeForeignWindowSession: ForeignWindowProfileSession {
    struct Presentation: Equatable {
        let targetFrame: CGRect?
        let isVisible: Bool
        let isFocused: Bool
        let raiseWindow: Bool
    }

    let profile: String
    private(set) var presentations: [Presentation] = []
    private(set) var invalidateCount = 0

    init(profile: String) {
        self.profile = profile
    }

    var isRunning: Bool { invalidateCount == 0 && !presentations.isEmpty }

    func updatePresentation(
        targetFrame: CGRect?,
        isVisible: Bool,
        isFocused: Bool,
        raiseWindow: Bool
    ) {
        presentations.append(
            Presentation(
                targetFrame: targetFrame,
                isVisible: isVisible,
                isFocused: isFocused,
                raiseWindow: raiseWindow
            )
        )
    }

    func invalidate() {
        invalidateCount += 1
    }
}

@MainActor
private final class FakeForeignWindowHost: ForeignWindowProfileHost {
    private(set) var isPresenting = false

    func foreignWindowProfileHostDidChangePresenting(_ isPresenting: Bool) {
        self.isPresenting = isPresenting
    }
}

@MainActor
private final class RegistryHarness {
    private(set) var created: [FakeForeignWindowSession] = []
    private(set) var registry: ForeignWindowProfileRegistry!

    init() {
        registry = ForeignWindowProfileRegistry(
            observesApplicationTermination: false
        ) { [unowned self] profile in
            let session = FakeForeignWindowSession(profile: profile)
            self.created.append(session)
            return session
        }
    }
}

@Suite
@MainActor
struct ForeignWindowProfileRegistryTests {
    private let frameA = CGRect(x: 0, y: 0, width: 400, height: 300)
    private let frameB = CGRect(x: 400, y: 0, width: 400, height: 300)

    @Test
    func testLeaseBookPrefersFocusedThenMostRecentlyShownHost() {
        var book = ForeignWindowLeaseBook()
        let panelA = UUID()
        let panelB = UUID()
        let hostA = UUID()
        let hostB = UUID()
        book.claim(profile: "work", panelID: panelA)
        book.claim(profile: "work", panelID: panelB)
        book.attach(hostID: hostA, panelID: panelA, profile: "work")
        book.attach(hostID: hostB, panelID: panelB, profile: "work")

        expectNil(book.presenter(for: "work"))

        book.update(hostID: hostA, isVisible: true, isFocused: false, targetFrame: frameA)
        book.update(hostID: hostB, isVisible: true, isFocused: false, targetFrame: frameB)
        expectEqual(book.presenter(for: "work"), hostB)

        book.update(hostID: hostA, isVisible: true, isFocused: true, targetFrame: frameA)
        expectEqual(book.presenter(for: "work"), hostA)

        book.update(hostID: hostA, isVisible: false, isFocused: false, targetFrame: nil)
        expectEqual(book.presenter(for: "work"), hostB)
    }

    @Test
    func testLeaseBookIgnoresHostsWhosePanelReleasedTheProfile() {
        var book = ForeignWindowLeaseBook()
        let panelA = UUID()
        let panelB = UUID()
        let hostA = UUID()
        book.claim(profile: "work", panelID: panelA)
        book.claim(profile: "work", panelID: panelB)
        book.attach(hostID: hostA, panelID: panelA, profile: "work")
        book.update(hostID: hostA, isVisible: true, isFocused: true, targetFrame: frameA)

        expectNil(book.release(panelID: panelA))
        expectNil(book.presenter(for: "work"))
        expectEqual(book.release(panelID: panelB), "work")
        expectFalse(book.isClaimed("work"))
    }

    @Test
    func testTwoPanesWithSameProfileShareOneSession() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let hostA = FakeForeignWindowHost()
        let hostB = FakeForeignWindowHost()
        let hostAID = UUID()
        let hostBID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "work", panelID: panelB)
        expectTrue(harness.created.isEmpty)

        registry.attach(host: hostA, hostID: hostAID, panelID: panelA, profile: "work")
        registry.attach(host: hostB, hostID: hostBID, panelID: panelB, profile: "work")
        expectTrue(harness.created.isEmpty)

        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: false, targetFrame: frameB, raiseWindow: false)

        expectEqual(harness.created.count, 1)
        expectTrue(hostA.isPresenting)
        expectFalse(hostB.isPresenting)
        expectEqual(harness.created.first?.presentations.last?.targetFrame, frameA)

        // Focus moves to B: B takes the window, A shows its placeholder.
        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: false, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: false)
        expectEqual(harness.created.count, 1)
        expectFalse(hostA.isPresenting)
        expectTrue(hostB.isPresenting)
        expectEqual(harness.created.first?.presentations.last?.targetFrame, frameB)
        expectEqual(harness.created.first?.presentations.last?.raiseWindow, true)
    }

    @Test
    func testViewTeardownDetachesWithoutTerminating() throws {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panel = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panel)
        registry.attach(host: host, hostID: hostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        let session = try #require(harness.created.first)

        registry.detach(hostID: hostID)
        expectEqual(session.invalidateCount, 0)
        expectEqual(session.presentations.last?.isVisible, false)

        // The pane re-mounts elsewhere (split move): same session, new host.
        let movedHost = FakeForeignWindowHost()
        let movedHostID = UUID()
        registry.attach(host: movedHost, hostID: movedHostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: movedHostID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: false)
        expectEqual(harness.created.count, 1)
        expectTrue(movedHost.isPresenting)
        expectEqual(session.presentations.last?.targetFrame, frameB)
    }

    @Test
    func testClosingLastPanelTerminatesButSharedProfileSurvives() throws {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "work", panelID: panelB)
        registry.attach(host: host, hostID: hostID, panelID: panelA, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        let session = try #require(harness.created.first)

        registry.releasePanel(panelA)
        expectEqual(session.invalidateCount, 0)
        expectFalse(host.isPresenting)
        expectEqual(registry.claimedProfiles, ["work"])

        registry.releasePanel(panelB)
        expectEqual(session.invalidateCount, 1)
        expectEqual(registry.sessionProfiles, [])
        expectEqual(registry.claimedProfiles, [])
    }

    @Test
    func testDifferentProfilesGetSeparateSessions() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panelA = UUID()
        let panelB = UUID()
        let hostA = FakeForeignWindowHost()
        let hostB = FakeForeignWindowHost()
        let hostAID = UUID()
        let hostBID = UUID()
        registry.claim(profile: "work", panelID: panelA)
        registry.claim(profile: "personal", panelID: panelB)
        registry.attach(host: hostA, hostID: hostAID, panelID: panelA, profile: "work")
        registry.attach(host: hostB, hostID: hostBID, panelID: panelB, profile: "personal")
        registry.updateHost(hostID: hostAID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)
        registry.updateHost(hostID: hostBID, isVisible: true, isFocused: false, targetFrame: frameB, raiseWindow: false)

        expectEqual(harness.created.map(\.profile).sorted(), ["personal", "work"])
        expectTrue(hostA.isPresenting)
        expectTrue(hostB.isPresenting)
    }

    @Test
    func testTerminateAllInvalidatesAndBlocksRelaunch() {
        let harness = RegistryHarness()
        let registry = harness.registry!
        let panel = UUID()
        let host = FakeForeignWindowHost()
        let hostID = UUID()
        registry.claim(profile: "work", panelID: panel)
        registry.attach(host: host, hostID: hostID, panelID: panel, profile: "work")
        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameA, raiseWindow: false)

        registry.terminateAll()
        expectEqual(harness.created.map(\.invalidateCount), [1])

        registry.updateHost(hostID: hostID, isVisible: true, isFocused: true, targetFrame: frameB, raiseWindow: true)
        expectEqual(harness.created.count, 1)
    }

    @Test
    func testProfilesOnDiskListsNormalizedDirectoriesOnly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-claude-profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        for name in ["work", "default", "Not Normalized"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: root.appendingPathComponent("stray-file"))

        expectEqual(
            ClaudeDesktopProfiles.profilesOnDisk(rootURL: root),
            ["default", "work"]
        )
    }
}
