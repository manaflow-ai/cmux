import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for naming the host after a colliding workspace title: which rows get a host, how much of
/// the host they show, and that the sidebar snapshot carries and displays it.
@MainActor
@Suite struct RemoteHostTitleSuffixesTests {
    private func entry(_ title: String, _ destination: String?) -> RemoteHostTitleSuffixes.Entry {
        RemoteHostTitleSuffixes.Entry(id: UUID(), title: title, destination: destination)
    }

    @Test func twoHostsWithTheSameTitleShowWhatTellsThemApart() {
        let a = entry("main", "user@web1.us-east.example.com")
        let b = entry("main", "user@web2.eu-west.example.com")
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [a, b])
        #expect(suffixes[a.id] == "web1.us-east")
        #expect(suffixes[b.id] == "web2.eu-west")
    }

    @Test func aRemoteWorkspaceBesideALocalOneShowsItsWholeHost() {
        let local = entry("main", nil)
        let remote = entry("main", "user@box.example.com")
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [local, remote])
        #expect(suffixes[local.id] == nil)
        #expect(suffixes[remote.id] == "box.example.com")
    }

    @Test func titlesThatDoNotCollideGetNoHost() {
        let a = entry("main", "a.example.com")
        let b = entry("work", "b.example.com")
        #expect(RemoteHostTitleSuffixes.suffixes(for: [a, b]).isEmpty)
    }

    @Test func workspacesOnOneHostGetNoHost() {
        // The host would not tell them apart, whichever user each one connects as.
        let a = entry("main", "user@box.example.com")
        let b = entry("main", "root@box.example.com")
        #expect(RemoteHostTitleSuffixes.suffixes(for: [a, b]).isEmpty)
    }

    @Test func aHostIsNeverTrimmedAway() {
        // Every label of example.com also ends box.example.com, so only the keep-one-label rule
        // stops the trim from emptying it.
        let a = entry("main", "example.com")
        let b = entry("main", "user@box.example.com")
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [a, b])
        #expect(suffixes[a.id] == "example")
        #expect(suffixes[b.id] == "box.example")

        let bare = entry("main", "com")
        let named = entry("main", "box.example.com")
        let short = RemoteHostTitleSuffixes.suffixes(for: [bare, named])
        #expect(short[bare.id] == "com")
        #expect(short[named.id] == "box.example.com")
    }

    @Test func ipAddressesKeepEveryLabel() {
        let a = entry("main", "user@192.168.1.20")
        let b = entry("main", "user@192.168.2.20")
        let v4 = RemoteHostTitleSuffixes.suffixes(for: [a, b])
        #expect(v4[a.id] == "192.168.1.20")
        #expect(v4[b.id] == "192.168.2.20")

        let c = entry("main", "::ffff:192.168.1.10")
        let d = entry("main", "::ffff:192.168.2.10")
        let mapped = RemoteHostTitleSuffixes.suffixes(for: [c, d])
        #expect(mapped[c.id] == "::ffff:192.168.1.10")
        #expect(mapped[d.id] == "::ffff:192.168.2.10")
    }

    @Test func cloudVMsAreToldApartByTheirVMId() {
        // Managed Cloud VMs share one gateway destination, so its host would name them all the same.
        let gateway = "vm-a+cmux@vm-ssh.example.com"
        #expect(RemoteHostTitleSuffixes.origin(destination: gateway, cloudVMID: "vm-a") == "vm-a")
        #expect(RemoteHostTitleSuffixes.origin(destination: "user@box.example.com", cloudVMID: nil) == "user@box.example.com")
        #expect(RemoteHostTitleSuffixes.origin(destination: nil, cloudVMID: nil) == nil)
        let a = entry("main", RemoteHostTitleSuffixes.origin(destination: "vm-a+cmux@vm-ssh.example.com", cloudVMID: "vm-a"))
        let b = entry("main", RemoteHostTitleSuffixes.origin(destination: "vm-b+cmux@vm-ssh.example.com", cloudVMID: "vm-b"))
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [a, b])
        #expect(suffixes[a.id] == "vm-a")
        #expect(suffixes[b.id] == "vm-b")
    }

    @Test func hostsThatDifferInTheLastLabelKeepEveryLabel() {
        let a = entry("main", "10.0.0.1")
        let b = entry("main", "10.0.0.2")
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [a, b])
        #expect(suffixes[a.id] == "10.0.0.1")
        #expect(suffixes[b.id] == "10.0.0.2")
    }

    @Test func aThreeWayCollisionTrimsOnlyWhatEveryHostShares() {
        let a = entry("main", "web1.us.example.com")
        let b = entry("main", "web2.us.example.com")
        let c = entry("main", "web1.eu.example.com")
        let suffixes = RemoteHostTitleSuffixes.suffixes(for: [a, b, c])
        #expect(suffixes[a.id] == "web1.us")
        #expect(suffixes[b.id] == "web2.us")
        #expect(suffixes[c.id] == "web1.eu")
    }

    @Test func surroundingWhitespaceDoesNotHideACollision() {
        let a = entry("main", "a.example.com")
        let b = entry("main ", "b.example.com")
        #expect(RemoteHostTitleSuffixes.suffixes(for: [a, b]).count == 2)
    }

    @Test func theRowDisplaysTheHostAfterTheTitle() {
        var snapshot = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(title: "main")
        #expect(snapshot.displayTitle == "main")
        snapshot.hostTitleSuffix = "web1.us-east"
        #expect(snapshot.displayTitle == "main · web1.us-east")
        #expect(snapshot.title == "main")
    }

    @Test func aContextMenuRefreshKeepsTheHost() {
        let displayed = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(title: "main")
        var next = SidebarWorkspaceSnapshotRefreshPolicyTests.snapshot(title: "main")
        next.hostTitleSuffix = "web1.us-east"
        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: displayed,
            next: next,
            force: false,
            contextMenuVisible: true
        )
        #expect(decision.workspaceSnapshotStorage?.hostTitleSuffix == "web1.us-east")
    }

    @Test func thePresentationKeyChangesWithTheHost() {
        let plain = SidebarWorkspaceSnapshotRefreshPolicyTests.presentationKey()
        var hosted = plain
        hosted.hostTitleSuffix = "web1.us-east"
        #expect(plain != hosted)
    }
}
