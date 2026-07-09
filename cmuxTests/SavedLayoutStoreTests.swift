import Foundation
import Testing
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private typealias WorkspaceDefinition = CmuxWorkspaces.CmuxWorkspaceDefinition
private typealias WorkspaceLayoutNode = CmuxWorkspaces.CmuxLayoutNode
private typealias WorkspacePaneDefinition = CmuxWorkspaces.CmuxPaneDefinition
private typealias WorkspaceSurfaceDefinition = CmuxWorkspaces.CmuxSurfaceDefinition

@MainActor
@Suite(.serialized)
struct SavedLayoutStoreTests {
    @Test func saveListGetDeleteRoundTrip() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)

        let layout = Self.layout(named: "Demo")
        try store.save(layout, overwrite: false)

        let listed = try store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "Demo")
        #expect(try store.layout(named: "demo")?.description == "Example")

        try store.delete(named: "DEMO")
        #expect(try store.list().isEmpty)
    }

    @Test func duplicateRejectedWithoutOverwriteAndReplacedWithOverwrite() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)

        try store.save(Self.layout(named: "Demo", description: "First"), overwrite: false)
        do {
            try store.save(Self.layout(named: "demo", description: "Second"), overwrite: false)
            Issue.record("Expected duplicate save to fail")
        } catch SavedLayoutStoreError.duplicateName(let name) {
            #expect(name == "demo")
        }

        try store.save(Self.layout(named: "demo", description: "Second"), overwrite: true)
        #expect(try store.list().count == 1)
        #expect(try store.layout(named: "DEMO")?.description == "Second")
    }

    @Test func blankNameRejected() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)

        do {
            try store.save(Self.layout(named: "   "), overwrite: false)
            Issue.record("Expected blank name save to fail")
        } catch SavedLayoutStoreError.blankName {
            #expect(true)
        }
    }

    @Test func corruptFileThrowsAndSaveRefusesToClobber() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.directoryURL, withIntermediateDirectories: true)
        try "{ not json".write(to: context.fileURL, atomically: true, encoding: .utf8)
        let store = SavedLayoutStore(fileURL: context.fileURL)

        do {
            _ = try store.list()
            Issue.record("Expected corrupt file to fail")
        } catch SavedLayoutStoreError.corruptFile {
            #expect(true)
        }

        do {
            try store.save(Self.layout(named: "Demo"), overwrite: false)
            Issue.record("Expected save to refuse corrupt file")
        } catch SavedLayoutStoreError.corruptFile {
            #expect(try String(contentsOf: context.fileURL) == "{ not json")
        }
    }

    @Test func deletingCorruptFileRecoversToEmptyState() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)
        #expect(try store.list().isEmpty)

        try FileManager.default.createDirectory(at: context.directoryURL, withIntermediateDirectories: true)
        try "{ not json".write(to: context.fileURL, atomically: true, encoding: .utf8)
        do {
            _ = try store.list()
            Issue.record("Expected corrupt file to fail")
        } catch SavedLayoutStoreError.corruptFile {
            #expect(true)
        }

        try FileManager.default.removeItem(at: context.fileURL)
        #expect(try store.list().isEmpty)
        try store.save(Self.layout(named: "Recovered"), overwrite: false)
        #expect(try store.list().map(\.name) == ["Recovered"])
    }

    @Test func externalFileEditIsPickedUpByMTimeCache() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)

        try store.save(Self.layout(named: "One"), overwrite: false)
        #expect(try store.list().map(\.name) == ["One"])

        let replacement = SavedLayoutStore.LayoutsFile(layouts: [Self.layout(named: "Two")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(replacement).write(to: context.fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4_102_444_800)],
            ofItemAtPath: context.fileURL.path
        )

        #expect(try store.list().map(\.name) == ["Two"])
    }

    @Test func onDiskShapeMatchesLayoutsArrayAndRedecodes() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)

        try store.save(Self.layout(named: "Demo"), overwrite: false)
        let data = try Data(contentsOf: context.fileURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["layouts"] is [[String: Any]])
        let decoded = try JSONDecoder().decode(SavedLayoutStore.LayoutsFile.self, from: data)
        #expect(decoded.layouts.count == 1)
        #expect(decoded.layouts.first?.name == "Demo")
    }

    private static func layout(named name: String, description: String? = "Example") -> CmuxSavedLayout {
        CmuxSavedLayout(
            name: name,
            description: description,
            workspace: WorkspaceDefinition(
                name: nil,
                cwd: "/tmp",
                color: nil,
                env: nil,
                layout: WorkspaceLayoutNode.pane(
                    WorkspacePaneDefinition(surfaces: [WorkspaceSurfaceDefinition(type: .terminal)])
                )
            )
        )
    }
}

struct TemporarySavedLayoutContext {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("layouts.json", isDirectory: false)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
