import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite struct WorkspaceTagsTests {
    @Test func normalizesTagsFromEditingText() {
        let tags = Workspace.customTags(fromEditingText: "  In CI  , waiting   for review\nin ci,, Ready ")

        #expect(tags == ["In CI", "waiting for review", "Ready"])
    }

    @Test func clampsCustomTagCountToMaximum() {
        // A large paste must not create thousands of long-lived tags that
        // scale sidebar projection / filter menu / autosave work.
        let manyTags = (0..<(Workspace.maxCustomTagCount + 50)).map { "tag\($0)" }
        let normalized = Workspace.normalizedCustomTags(manyTags)

        #expect(normalized.count == Workspace.maxCustomTagCount)
        // Keeps the first N distinct tags in order.
        #expect(normalized.first == "tag0")
        #expect(normalized.last == "tag\(Workspace.maxCustomTagCount - 1)")
    }

    @Test func clampsCustomTagLengthToMaximum() {
        // A single multi-kilobyte token must be truncated, not stored whole.
        let longTag = String(repeating: "a", count: Workspace.maxCustomTagLength + 25)
        let normalized = Workspace.normalizedCustomTags([longTag])

        #expect(normalized.count == 1)
        #expect(normalized.first?.count == Workspace.maxCustomTagLength)
    }

    @Test func customTagsFromEditingTextCapsCountForManyCommaSeparatedTags() {
        // The editing-text path tokenizes lazily, but a huge comma-separated
        // paste must still be capped to the count limit (keeping the first N
        // distinct tags in order) rather than materializing every token.
        let text = (0..<(Workspace.maxCustomTagCount + 100))
            .map { "tag\($0)" }
            .joined(separator: ",")
        let tags = Workspace.customTags(fromEditingText: text)

        #expect(tags.count == Workspace.maxCustomTagCount)
        #expect(tags.first == "tag0")
        #expect(tags.last == "tag\(Workspace.maxCustomTagCount - 1)")
    }

    @Test func customTagsFromEditingTextBoundsGiantTokenScan() {
        // A single multi-megabyte field is truncated to the length cap AND the
        // tokenizer stops within its total-scan budget instead of walking the
        // whole field to look for a following delimiter. Tail input after such a
        // pathological field is intentionally dropped — bounding main-thread
        // work takes priority over parsing tags that trail megabytes of junk.
        let huge = String(repeating: "a", count: 2_000_000)
        let tags = Workspace.customTags(fromEditingText: huge + ",Ready")

        #expect(tags == [String(repeating: "a", count: Workspace.maxCustomTagLength)])
    }

    @Test func customTagsFromEditingTextBoundsEmptyAndDuplicateFloodInput() {
        // Empty tokens (bare commas) and duplicate tokens hit the normalizer's
        // `continue` paths without raising the accepted-tag count, so neither the
        // per-token cap nor the count cap bounds them. The total-scan budget must
        // stop the tokenizer rather than let it walk the entire pasted string on
        // the main actor.
        let commaFlood = String(repeating: ",", count: 5_000_000)
        #expect(Workspace.customTags(fromEditingText: commaFlood).isEmpty)

        let duplicateFlood = String(repeating: "dup,", count: 5_000_000)
        #expect(Workspace.customTags(fromEditingText: duplicateFlood) == ["dup"])
    }

    @Test func normalizedCustomTagsTrimsTrailingSpaceLeftByLengthTruncation() {
        // When the length cap falls exactly on the space that joins two
        // collapsed words, the stored tag must not keep that trailing separator.
        let head = String(repeating: "a", count: Workspace.maxCustomTagLength - 1)
        let normalized = Workspace.normalizedCustomTags(["\(head) tail"])

        #expect(normalized == [head])
        #expect(normalized.first?.hasSuffix(" ") == false)
    }

    @Test func customTagsMatchFilterCaseAndDiacriticInsensitively() {
        // The sidebar tag filter and the Shift-click range clamp both match
        // through this shared helper, so "In CI" must match a workspace tagged
        // "in ci" while an unrelated tag does not.
        #expect(Workspace.customTags(["in ci", "Ready"], containMatchFor: "In CI"))
        #expect(Workspace.customTags(["café"], containMatchFor: "cafe"))
        #expect(!Workspace.customTags(["Ready"], containMatchFor: "In CI"))
        #expect(!Workspace.customTags([], containMatchFor: "In CI"))
    }

    @Test func tabManagerAppliesTagsThroughSharedMutationPath() throws {
        let manager = TabManager()
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(title: "Review", select: false, eagerLoadTerminal: false)

        manager.applyWorkspaceTags(editingText: "In CI, Waiting for review", toWorkspaceIds: [first.id, second.id])

        #expect(first.customTags == ["In CI", "Waiting for review"])
        #expect(second.customTags == ["In CI", "Waiting for review"])

        manager.clearWorkspaceTags(forWorkspaceIds: [first.id, second.id])
        #expect(first.customTags.isEmpty)
        #expect(second.customTags.isEmpty)
    }

    @Test func workspaceTagsSurviveSessionSnapshotRestore() {
        let source = Workspace()
        source.setCustomTags(["In CI", "Waiting for review"])

        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.customTags == ["In CI", "Waiting for review"])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.customTags == ["In CI", "Waiting for review"])
    }

    @Test func workspaceTagsParticipateInAutosaveFingerprint() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let before = manager.sessionAutosaveFingerprint()

        manager.setCustomTags(tabId: workspace.id, editingText: "In CI")

        #expect(manager.sessionAutosaveFingerprint() != before)
    }

    @Test func emptyWorkspaceTagsAreOmittedAndLegacySnapshotsDecode() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )

        let data = try JSONEncoder().encode(snapshot)
        let raw = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(raw["customTags"] == nil)

        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.customTags == nil)
    }

    @Test func sidebarImmediateObservationPublisherEmitsWhenTagsChange() {
        let workspace = Workspace()
        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setCustomTags(["In CI"])

        #expect(publishCount > 0)
    }
}
