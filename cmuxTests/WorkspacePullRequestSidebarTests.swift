import XCTest
import Darwin
import CmuxProcess

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@discardableResult
private func waitForCondition(
    timeout: TimeInterval = 3.0,
    pollInterval: TimeInterval = 0.05,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) -> Bool {
    if condition() {
        return true
    }

    let expectation = XCTestExpectation(description: "wait for condition")
    let deadline = Date().addingTimeInterval(timeout)

    func poll() {
        if condition() {
            expectation.fulfill()
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll()
        }
    }

    DispatchQueue.main.async {
        poll()
    }

    let result = XCTWaiter().wait(for: [expectation], timeout: timeout + pollInterval + 0.1)
    if result != .completed {
        XCTFail("Timed out waiting for condition", file: file, line: line)
        return false
    }
    return true
}

@MainActor
final class WorkspacePullRequestSidebarTests: XCTestCase {
    func testReenablingGitWatchRestartsRefreshFromCurrentPanelDirectories() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-reenable-git-watch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
            },
            "Re-enabling git watch must restart probes from the panel's current directory."
        )
    }

    func testDetachedHeadRepositoryKeepsGitMetadataWatcherForLaterCheckout() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-detached-head-watch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try "0000000000000000000000000000000000000000\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                manager.trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: workspace.id).contains(panelId)
            },
            "Detached HEAD repos must stay tracked so later .git/HEAD updates refresh sidebar metadata."
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])

        try "ref: refs/heads/main\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
            },
            "Refreshing a tracked detached-HEAD repo after checkout must restore branch metadata."
        )
    }

    // Removed testBackgroundGitMetadataFallbackContinuesWithinOversizedWorkspace:
    // it asserted the branch's batched/cursor git-metadata polling
    // (backgroundGitMetadataPollBatchLimit), which main's refactor replaced with
    // a full sweep (refreshTrackedWorkspaceGitMetadata now returns Void). Git
    // metadata behavior is covered by CmuxGit/GitMetadataServiceTests; restoring
    // the batched throttle + this test is a deliberate follow-up if mobile-host
    // scale needs it.

    func testUnrelatedDefaultsChangeDoesNotRestartGitMetadataRefreshes() throws {
        let defaults = UserDefaults.standard
        let unrelatedDefaultsKey = "cmux.tests.unrelated-defaults-\(UUID().uuidString)"
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            defaults.removeObject(forKey: unrelatedDefaultsKey)
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let workingDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-unrelated-defaults-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workingDirectoryURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        XCTAssertTrue(
            waitForCondition(timeout: 12.0) {
                manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id).isEmpty
            }
        )

        workspace.currentDirectory = workingDirectoryURL.path
        defaults.set(UUID().uuidString, forKey: unrelatedDefaultsKey)
        manager.sidebarGitMetadataWatchSettingsDidChangeForTesting()

        XCTAssertEqual(
            manager.activeWorkspaceGitProbePanelIdsForTesting(workspaceId: workspace.id),
            Set<UUID>(),
            "Unrelated UserDefaults writes must not restart sidebar git probes for every panel."
        )
        XCTAssertNil(workspace.panelGitBranches[panelId])
    }

    func testGitIndexVersionFourRefreshTracksIndexSignatureChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-index-v4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try "seed\n".write(
            to: repoURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion4(at: repoURL, trackedPath: "tracked.txt", signatureByte: 0x11)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "The sidebar refresh path should parse Git index v4 entries as clean when file stats match."
        )

        try writeGitIndexVersion4(at: repoURL, trackedPath: "tracked.txt", signatureByte: 0x22)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Index v4 signature changes should keep staged/index-only changes visible as dirty."
        )
    }

    func testCleanIndexSignatureRebaselinesWhenIndexRewriteKeepsTrackedContentClean() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-stash-clean-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let cleanObjectID = Array(repeating: UInt8(0x11), count: 20)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: cleanObjectID
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A matching index and worktree should establish a clean baseline."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "A worktree edit should make the sidebar dirty before a simulated stash."
        )

        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: cleanObjectID
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A stash-like index rewrite with unchanged tracked content should become the new clean baseline."
        )
    }

    func testIndexContentChangeAfterWorktreeDirtyRemainsDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-staged-after-dirty-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: Array(repeating: UInt8(0x11), count: 20)
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A matching index and worktree should establish a clean baseline."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "A worktree edit should make the sidebar dirty before staging."
        )

        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: Array(repeating: UInt8(0x22), count: 20)
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Staging changed content should remain dirty even when the index stat cache matches the worktree."
        )
    }

    func testAssumeUnchangedGitIndexEntriesDoNotMarkModifiedWorktreeDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-assume-unchanged-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let trackedURL = repoURL.appendingPathComponent("tracked.txt")
        try "seed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        let cleanObjectID = Array(repeating: UInt8(0x11), count: 20)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x11,
            objectIDBytes: cleanObjectID
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A matching index and worktree should establish a clean baseline."
        )

        let assumeUnchangedFlag: UInt16 = 0x8000
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "tracked.txt",
            indexMode: 0o100644,
            signatureByte: 0x22,
            objectIDBytes: cleanObjectID,
            baseFlags: assumeUnchangedFlag
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Setting assume-unchanged should rebaseline as clean because tracked index content did not change."
        )

        try "changed\n".write(to: trackedURL, atomically: true, encoding: .utf8)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Assume-unchanged index entries should not stat modified worktree files."
        )
    }

    func testGitIndexVersionFourRefreshDecodesMultiByteStripLengths() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-index-v4-varint-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let longTrackedPath = [
            "a",
            String(repeating: "a", count: 120),
            String(repeating: "b", count: 120),
            "tracked0.txt"
        ].joined(separator: "/")
        XCTAssertEqual(longTrackedPath.utf8.count, 256)
        XCTAssertEqual(gitIndexV4PathStripLengthBytes(256), [0x81, 0x00])

        let longTrackedFileURL = repoURL.appendingPathComponent(longTrackedPath)
        try FileManager.default.createDirectory(
            at: longTrackedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(to: longTrackedFileURL, atomically: true, encoding: .utf8)
        try "beta\n".write(to: repoURL.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion4(
            at: repoURL,
            trackedPaths: [longTrackedPath, "b.txt"],
            signatureByte: 0x33
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Index v4 multi-byte path strip lengths should decode to the tracked path instead of marking the repo dirty."
        )
    }

    func testEmptyGitIndexRefreshTracksIndexSignatureChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-empty-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeEmptyGitIndex(at: repoURL, signatureByte: 0x11)
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )
        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A valid empty index should establish a clean signature baseline."
        )

        try writeEmptyGitIndex(at: repoURL, signatureByte: 0x22)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Empty-index signature changes should keep staged deletes visible as dirty."
        )
    }

    func testSkipWorktreeGitIndexEntriesDoNotMarkSparseCheckoutDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-sparse-index-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion3SkipWorktreeEntry(
            at: repoURL,
            trackedPath: "sparse-only.txt",
            signatureByte: 0x44
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repoURL.appendingPathComponent("sparse-only.txt").path),
            "The sparse-checkout entry should be absent from the worktree."
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Skip-worktree index entries should be ignored by dirty detection when sparse files are absent."
        )
    }

    func testMissingGitlinkSubmoduleMarksSidebarDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-gitlink-index-\(UUID().uuidString)",
            isDirectory: true
        )
        let submoduleURL = repoURL.appendingPathComponent("vendor/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: submoduleURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeGitIndexVersion2Entry(
            at: repoURL,
            trackedPath: "vendor/lib",
            mode: 0o160000,
            size: 0,
            signatureByte: 0x33
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Missing or uninitialized gitlink submodules should make the parent sidebar dirty."
        )
    }

    func testGitlinkIndexEntriesTrackSubmoduleCommitChanges() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-gitlink-commit-\(UUID().uuidString)",
            isDirectory: true
        )
        let submoduleURL = repoURL.appendingPathComponent("vendor/lib", isDirectory: true)
        let indexedCommit = String(repeating: "1", count: 40)
        let updatedCommit = String(repeating: "2", count: 40)
        try FileManager.default.createDirectory(at: submoduleURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        try writeMinimalGitRepository(at: submoduleURL, headCommit: indexedCommit)
        try writeGitIndexVersion2Entry(
            at: repoURL,
            trackedPath: "vendor/lib",
            mode: 0o160000,
            size: 0,
            signatureByte: 0x66,
            objectIDBytes: gitObjectIDBytes(indexedCommit)
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A gitlink whose worktree HEAD matches the indexed submodule commit should be clean."
        )

        try "\(updatedCommit)\n".write(
            to: submoduleURL.appendingPathComponent(".git/refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Submodule HEAD changes should make the parent sidebar dirty without spawning git."
        )
    }

    // Git-metadata resolution, watched-path derivation (including submodule
    // gitlinks), and remote-slug parsing now live in the CmuxGit package and are
    // unit-tested there (CmuxGitTests: GitMetadataServiceTests / GitConfigIncludeTests).
    // The watcher's leading-edge coalescing is verified in CmuxFileWatch's package
    // tests (RecursivePathWatcherTests) with an injected clock and no real waiting.
    // The tests below keep exercising the end-to-end refresh path through TabManager.

    func testModeOnlyTrackedChangesMarkSidebarDirty() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-mode-only-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let scriptURL = repoURL.appendingPathComponent("script.sh")
        try "echo ok\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(scriptURL.path, 0o644), 0)
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "script.sh",
            indexMode: 0o100644,
            signatureByte: 0x44
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "A tracked file with matching size, mtime, and mode should establish a clean baseline."
        )

        XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
        manager.refreshTrackedWorkspaceGitMetadataForTesting()

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.isDirty == true
            },
            "Mode-only changes should be visible as dirty without invoking git."
        )
    }

    func testLargeTrackedFileSizeMatchesGitIndexTruncation() throws {
        let defaults = UserDefaults.standard
        let previousWatchGitStatus = defaults.object(forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        defer {
            restoreUserDefault(previousWatchGitStatus, key: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        }

        let repoURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-large-file-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try writeMinimalGitRepository(at: repoURL)
        let largeURL = repoURL.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: largeURL.path, contents: Data(), attributes: nil))
        let handle = try FileHandle(forWritingTo: largeURL)
        try handle.truncate(atOffset: UInt64(UInt32.max) + 257)
        try handle.close()
        try writeGitIndexVersion2EntryFromStat(
            at: repoURL,
            trackedPath: "large.bin",
            indexMode: 0o100644,
            signatureByte: 0x55
        )
        defer {
            try? FileManager.default.removeItem(at: repoURL)
        }

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.watchGitStatusKey)
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)

        manager.updateSurfaceDirectory(
            tabId: workspace.id,
            surfaceId: panelId,
            directory: repoURL.path
        )

        XCTAssertTrue(
            waitForCondition {
                workspace.panelGitBranches[panelId]?.branch == "main"
                    && workspace.panelGitBranches[panelId]?.isDirty == false
            },
            "Git index stores file size as a 32-bit field; matching large sparse files should compare with truncation, not clamping."
        )
    }
}

func restoreUserDefault(_ value: Any?, key: String) {
    let defaults = UserDefaults.standard
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}
