import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ProfileStoreTests: XCTestCase {

    // MARK: - Profile Model Codable Round-Trip

    func testProfileEncodesAndDecodesRoundTrip() throws {
        let snapshot = makeTabManagerSnapshot(workspaceCount: 2)
        let profile = Profile(name: "Work", snapshot: snapshot)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(profile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Profile.self, from: data)

        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, "Work")
        XCTAssertEqual(decoded.snapshot.workspaces.count, 2)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            profile.createdAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testProfilePreservesAllWorkspaceSnapshotFields() throws {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "zsh",
            customTitle: "My Terminal",
            customColor: "#C0392B",
            isPinned: true,
            currentDirectory: "/Users/test/project",
            focusedPanelId: UUID(),
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: SessionProgressSnapshot(value: 0.5, label: "Building"),
            gitBranch: SessionGitBranchSnapshot(branch: "main", isDirty: true)
        )
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace]
        )
        let profile = Profile(name: "Full", snapshot: snapshot)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(profile)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Profile.self, from: data)

        let ws = decoded.snapshot.workspaces[0]
        XCTAssertEqual(ws.processTitle, "zsh")
        XCTAssertEqual(ws.customTitle, "My Terminal")
        XCTAssertEqual(ws.customColor, "#C0392B")
        XCTAssertTrue(ws.isPinned)
        XCTAssertEqual(ws.currentDirectory, "/Users/test/project")
        XCTAssertEqual(ws.progress?.value, 0.5)
        XCTAssertEqual(ws.progress?.label, "Building")
        XCTAssertEqual(ws.gitBranch?.branch, "main")
        XCTAssertTrue(ws.gitBranch?.isDirty == true)
    }

    func testProfileDecodesWithMissingOptionalFields() throws {
        // Simulate a profile saved by an older version without optional fields.
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "createdAt": 1700000000,
            "updatedAt": 1700000000,
            "snapshot": {
                "workspaces": [
                    {
                        "processTitle": "zsh",
                        "isPinned": false,
                        "currentDirectory": "/tmp",
                        "layout": {
                            "type": "pane",
                            "pane": { "panelIds": [] }
                        },
                        "panels": [],
                        "statusEntries": [],
                        "logEntries": []
                    }
                ]
            }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(Profile.self, from: data)

        XCTAssertEqual(profile.name, "Legacy")
        XCTAssertEqual(profile.snapshot.workspaces.count, 1)
        XCTAssertNil(profile.snapshot.workspaces[0].customTitle)
        XCTAssertNil(profile.snapshot.workspaces[0].customColor)
        XCTAssertNil(profile.snapshot.workspaces[0].gitBranch)
        XCTAssertNil(profile.snapshot.workspaces[0].progress)
        XCTAssertNil(profile.snapshot.selectedWorkspaceIndex)
    }

    // MARK: - ProfileStore Save / Load / Delete

    func testSaveAndLoadByName() throws {
        let snapshot = makeTabManagerSnapshot(workspaceCount: 3)
        var profile = Profile(name: "SaveLoad", snapshot: snapshot)
        profile.updatedAt = Date()

        XCTAssertTrue(ProfileStore.save(profile))

        let loaded = ProfileStore.load(name: "SaveLoad")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, profile.id)
        XCTAssertEqual(loaded?.name, "SaveLoad")
        XCTAssertEqual(loaded?.snapshot.workspaces.count, 3)

        ProfileStore.delete(name: "SaveLoad")
    }

    func testSaveOverwritePreservesContent() throws {
        let snapshot1 = makeTabManagerSnapshot(workspaceCount: 1)
        var profile1 = Profile(name: "Overwrite", snapshot: snapshot1)
        XCTAssertTrue(ProfileStore.save(profile1))

        let snapshot2 = makeTabManagerSnapshot(workspaceCount: 5)
        profile1.snapshot = snapshot2
        profile1.updatedAt = Date()
        XCTAssertTrue(ProfileStore.save(profile1))

        let loaded = ProfileStore.load(name: "Overwrite")
        XCTAssertEqual(loaded?.snapshot.workspaces.count, 5)

        ProfileStore.delete(name: "Overwrite")
    }

    func testDeleteRemovesProfile() {
        let profile = Profile(name: "ToDelete", snapshot: makeTabManagerSnapshot(workspaceCount: 1))
        ProfileStore.save(profile)
        XCTAssertNotNil(ProfileStore.load(name: "ToDelete"))

        XCTAssertTrue(ProfileStore.delete(name: "ToDelete"))
        XCTAssertNil(ProfileStore.load(name: "ToDelete"))
    }

    func testDeleteNonExistentReturnsFalse() {
        XCTAssertFalse(ProfileStore.delete(name: "NonExistent-\(UUID().uuidString)"))
    }

    func testLoadNonExistentReturnsNil() {
        XCTAssertNil(ProfileStore.load(name: "NonExistent-\(UUID().uuidString)"))
    }

    // MARK: - List

    func testListReturnsSortedProfiles() {
        let names = ["Zebra", "Alpha", "Middle"]
        for name in names {
            ProfileStore.save(Profile(name: name, snapshot: makeTabManagerSnapshot(workspaceCount: 1)))
        }
        defer {
            for name in names { ProfileStore.delete(name: name) }
        }

        let profiles = ProfileStore.list()
        let listed = profiles.map(\.name)

        guard let alphaIdx = listed.firstIndex(of: "Alpha"),
              let middleIdx = listed.firstIndex(of: "Middle"),
              let zebraIdx = listed.firstIndex(of: "Zebra") else {
            XCTFail("Expected all three profiles in list")
            return
        }
        XCTAssertLessThan(alphaIdx, middleIdx)
        XCTAssertLessThan(middleIdx, zebraIdx)
    }

    func testLoadById() {
        let profile = Profile(name: "ById", snapshot: makeTabManagerSnapshot(workspaceCount: 1))
        ProfileStore.save(profile)
        defer { ProfileStore.delete(name: "ById") }

        let loaded = ProfileStore.load(id: profile.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "ById")
    }

    // MARK: - Rename

    func testRenameProfile() {
        ProfileStore.save(Profile(name: "OldName", snapshot: makeTabManagerSnapshot(workspaceCount: 2)))
        defer { ProfileStore.delete(name: "NewName") }

        let renamed = ProfileStore.rename(oldName: "OldName", newName: "NewName")
        XCTAssertNotNil(renamed)
        XCTAssertEqual(renamed?.name, "NewName")
        XCTAssertEqual(renamed?.snapshot.workspaces.count, 2)

        XCTAssertNil(ProfileStore.load(name: "OldName"))
        XCTAssertNotNil(ProfileStore.load(name: "NewName"))
    }

    func testRenameToExistingNameFails() {
        ProfileStore.save(Profile(name: "First", snapshot: makeTabManagerSnapshot(workspaceCount: 1)))
        ProfileStore.save(Profile(name: "Second", snapshot: makeTabManagerSnapshot(workspaceCount: 1)))
        defer {
            ProfileStore.delete(name: "First")
            ProfileStore.delete(name: "Second")
        }

        let result = ProfileStore.rename(oldName: "First", newName: "Second")
        XCTAssertNil(result)

        // Both should still exist.
        XCTAssertNotNil(ProfileStore.load(name: "First"))
        XCTAssertNotNil(ProfileStore.load(name: "Second"))
    }

    func testRenameEmptyNameFails() {
        XCTAssertNil(ProfileStore.rename(oldName: "Anything", newName: "   "))
    }

    func testRenameNonExistentFails() {
        XCTAssertNil(ProfileStore.rename(oldName: "Ghost-\(UUID().uuidString)", newName: "New"))
    }

    // MARK: - Filename Sanitization

    func testProfileWithSpecialCharactersInName() {
        let name = "Work/Project: Test<1>"
        ProfileStore.save(Profile(name: name, snapshot: makeTabManagerSnapshot(workspaceCount: 1)))
        defer { ProfileStore.delete(name: name) }

        let loaded = ProfileStore.load(name: name)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, name)
    }

    // MARK: - Active Profile on TabManager

    @MainActor
    func testActiveProfileNameIsNilByDefault() {
        let manager = TabManager()
        XCTAssertNil(manager.activeProfileName)
    }

    @MainActor
    func testSetAndClearActiveProfileName() {
        let manager = TabManager()
        manager.setActiveProfileName("Work")
        XCTAssertEqual(manager.activeProfileName, "Work")

        manager.setActiveProfileName(nil)
        XCTAssertNil(manager.activeProfileName)
    }

    @MainActor
    func testActiveProfilePersistsAfterAddingWorkspace() {
        let manager = TabManager()
        manager.setActiveProfileName("Work")

        _ = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        XCTAssertEqual(manager.activeProfileName, "Work")
    }

    @MainActor
    func testLoadingDifferentProfileReplacesActiveProfileName() {
        let manager = TabManager()
        manager.setActiveProfileName("Work")

        // Simulate loading a different profile.
        let snapshot = makeTabManagerSnapshot(workspaceCount: 2)
        manager.restoreSessionSnapshot(snapshot)
        manager.setActiveProfileName("Personal")

        XCTAssertEqual(manager.activeProfileName, "Personal")
    }

    // MARK: - Snapshot Selection Preservation

    func testProfilePreservesSelectedWorkspaceIndex() {
        let snapshot = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 2,
            workspaces: (0..<4).map { makeWorkspaceSnapshot(title: "WS \($0)") }
        )
        let profile = Profile(name: "Selection", snapshot: snapshot)
        ProfileStore.save(profile)
        defer { ProfileStore.delete(name: "Selection") }

        let loaded = ProfileStore.load(name: "Selection")
        XCTAssertEqual(loaded?.snapshot.selectedWorkspaceIndex, 2)
        XCTAssertEqual(loaded?.snapshot.workspaces.count, 4)
    }

    // MARK: - Helpers

    private func makeTabManagerSnapshot(workspaceCount: Int) -> SessionTabManagerSnapshot {
        SessionTabManagerSnapshot(
            selectedWorkspaceIndex: workspaceCount > 0 ? 0 : nil,
            workspaces: (0..<workspaceCount).map { makeWorkspaceSnapshot(title: "Terminal \($0 + 1)") }
        )
    }

    private func makeWorkspaceSnapshot(title: String) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: title,
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
    }
}
