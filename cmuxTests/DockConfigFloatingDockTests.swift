import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock config Floating Docks", .serialized)
struct DockConfigFloatingDockTests {
    private func decode(_ json: String) throws -> DockConfigFile {
        try JSONDecoder().decode(DockConfigFile.self, from: Data(json.utf8))
    }

    private func resolution(
        sourcePath: String = "/repo/.cmux/dock.json",
        floats: [DockFloatingDockDefinition]
    ) -> DockConfigResolution {
        DockConfigResolution(
            controls: [],
            floats: floats,
            sourceURL: URL(fileURLWithPath: sourcePath),
            baseDirectory: URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
                .deletingLastPathComponent().path,
            isProjectSource: true
        )
    }

    private func noteFloat(
        id: String,
        title: String,
        frame: DockFloatingDockFrameDefinition? = nil
    ) -> DockFloatingDockDefinition {
        DockFloatingDockDefinition(
            id: id,
            title: title,
            frame: frame,
            content: DockControlDefinition(
                id: "note",
                title: "Notes",
                kind: .note
            )
        )
    }

    @Test("Legacy controls-only files decode and encode unchanged")
    func legacyControlsOnlyFileRoundTripsWithoutFloats() throws {
        let file = try decode(
            #"{"controls":[{"id":"git","title":"Git","command":"lazygit"}]}"#
        )

        #expect(file.controls.count == 1)
        #expect(file.floats.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try #require(String(data: try encoder.encode(file), encoding: .utf8))
        #expect(encoded == #"{"controls":[{"command":"lazygit","id":"git","title":"Git"}]}"#)
    }

    @Test("Unified files decode terminal, browser, and note float content")
    func unifiedFileDecodesAllFloatContentKinds() throws {
        let file = try decode(
            #"""
            {
              "controls": [{"id": "git", "title": "Git", "command": "lazygit"}],
              "floats": [
                {
                  "id": "server",
                  "title": "Server",
                  "frame": {"x": 44, "y": 72, "width": 640, "height": 420},
                  "content": {"id": "dev", "title": "Dev", "command": "pnpm dev", "cwd": "."}
                },
                {
                  "id": "preview",
                  "title": "Preview",
                  "content": {"id": "web", "title": "Web", "type": "browser", "url": "https://example.com"}
                },
                {
                  "id": "notes",
                  "title": "Notes",
                  "content": {"id": "scratch", "title": "Scratch", "type": "note"}
                }
              ]
            }
            """#
        )

        #expect(file.controls.count == 1)
        #expect(file.floats.map(\.id) == ["server", "preview", "notes"])
        #expect(file.floats[0].content?.kind == .terminal)
        #expect(file.floats[1].content?.kind == .browser)
        #expect(file.floats[2].content?.kind == .note)
        #expect(file.floats[0].frame?.width == 640)
        #expect(file.floats[0].frame?.height == 420)
    }

    @Test("Float frame and content have sane defaults")
    func floatDefaultsDecode() throws {
        let file = try decode(#"{"floats":[{"id":"scratch","title":"Scratch"}]}"#)
        let definition = try #require(file.floats.first)

        #expect(definition.content == nil)
        #expect(definition.resolvedFrame(cascadeIndex: 2) == CGRect(
            x: 84,
            y: 32,
            width: 520,
            height: 380
        ))
    }

    @Test("Unknown and malformed Dock config sections throw")
    func unknownAndMalformedSectionsThrow() {
        let invalidDocuments = [
            #"{"controls":[],"floatingDocks":[]}"#,
            #"{"controls":null}"#,
            #"{"floats":null}"#,
            #"{"floats":{}}"#,
            #"{"floats":[{"id":"x","title":"X","widht":500}]}"#,
            #"{"floats":[{"id":"x","title":"X","frame":{"w":500}}]}"#,
            #"{"floats":[{"id":"x","title":"X","content":{"id":"n","type":"note","script":"echo"}}]}"#,
            #"{"floats":[{"id":"x","title":"X","content":{"id":"n","type":"note","command":"echo"}}]}"#,
            #"{"floats":[{"id":"x","title":"X","frame":{"width":100,"height":300}}]}"#,
        ]

        for json in invalidDocuments {
            #expect(throws: (any Error).self) {
                _ = try decode(json)
            }
        }
    }

    @Test("Duplicate float ids and note controls in the right Dock throw")
    func invalidIdentitiesAndRightDockNoteThrow() {
        #expect(throws: (any Error).self) {
            _ = try decode(
                #"{"floats":[{"id":"same","title":"One"},{"id":"same","title":"Two"}]}"#
            )
        }
        #expect(throws: (any Error).self) {
            _ = try decode(
                #"{"controls":[{"id":"note","title":"Note","type":"note"}]}"#
            )
        }
    }

    @Test("Global config rejects Floating Docks loudly")
    func globalConfigRejectsFloats() throws {
        let file = try decode(#"{"floats":[{"id":"scratch","title":"Scratch"}]}"#)

        #expect(throws: (any Error).self) {
            try file.validate(isProjectSource: false)
        }
    }

    @Test("Applying the same seed is idempotent and newly added ids seed later")
    @MainActor
    func seedOnceAndAddNewIDs() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let first = noteFloat(
            id: "scratch",
            title: "Scratch",
            frame: DockFloatingDockFrameDefinition(x: 12, y: 34, width: 700, height: 500)
        )

        let edited = noteFloat(
            id: "scratch",
            title: "Edited Config Title",
            frame: DockFloatingDockFrameDefinition(x: 1, y: 2, width: 500, height: 400)
        )
        workspace.applyFloatingDockConfiguration(resolution(floats: [first]))
        let seeded = try #require(workspace.floatingDocks.first)
        seeded.title = "My Scratch"
        seeded.frame = CGRect(x: 101, y: 202, width: 801, height: 602)

        workspace.applyFloatingDockConfiguration(resolution(floats: [edited]))
        #expect(workspace.floatingDocks.count == 1)
        #expect(workspace.floatingDocks[0].title == "My Scratch")
        #expect(workspace.floatingDocks[0].frame == CGRect(x: 101, y: 202, width: 801, height: 602))

        workspace.applyFloatingDockConfiguration(resolution(floats: [
            first,
            noteFloat(id: "preview", title: "Preview"),
        ]))
        #expect(workspace.floatingDocks.count == 2)
        #expect(workspace.floatingDocks[1].frame == CGRect(x: 60, y: 56, width: 520, height: 380))
    }

    @Test("Session-restored config floats keep user state and do not duplicate")
    @MainActor
    func sessionRestoreWinsOverConfigSeed() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let config = resolution(floats: [noteFloat(id: "scratch", title: "Scratch")])
        source.applyFloatingDockConfiguration(config)
        let sourceDock = try #require(source.floatingDocks.first)
        sourceDock.title = "User Title"
        sourceDock.frame = CGRect(x: 123, y: 234, width: 777, height: 555)
        sourceDock.isPresented = false

        let encoded = try JSONEncoder().encode(source.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        _ = restored.restoreSessionSnapshot(snapshot)

        restored.applyFloatingDockConfiguration(config)

        let restoredDock = try #require(restored.floatingDocks.first)
        #expect(restored.floatingDocks.count == 1)
        #expect(restoredDock.title == "User Title")
        #expect(restoredDock.frame == CGRect(x: 123, y: 234, width: 777, height: 555))
        #expect(!restoredDock.isPresented)
    }

    @Test("A closed config float stays closed after session restore")
    @MainActor
    func closedSeedStaysClosed() throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let config = resolution(floats: [noteFloat(id: "scratch", title: "Scratch")])
        source.applyFloatingDockConfiguration(config)
        let dockID = try #require(source.floatingDocks.first?.id)
        #expect(source.closeFloatingDock(id: dockID))

        let encoded = try JSONEncoder().encode(source.sessionSnapshot(includeScrollback: false))
        let snapshot = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: encoded)
        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        _ = restored.restoreSessionSnapshot(snapshot)

        restored.applyFloatingDockConfiguration(config)
        #expect(restored.floatingDocks.isEmpty)
    }

    @Test("The same float id in a different config source is a new seed")
    @MainActor
    func seedIdentityIncludesConfigSource() {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let definition = noteFloat(id: "scratch", title: "Scratch")

        workspace.applyFloatingDockConfiguration(resolution(
            sourcePath: "/repo-a/.cmux/dock.json",
            floats: [definition]
        ))
        workspace.applyFloatingDockConfiguration(resolution(
            sourcePath: "/repo-b/.cmux/dock.json",
            floats: [definition]
        ))

        #expect(workspace.floatingDocks.count == 2)
    }

    @Test("The config-only loader is not exposed as a routable Dock")
    @MainActor
    func configurationLoaderDoesNotRegisterForDockRouting() {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }

        let store = workspace.floatingDockConfigurationStore()

        #expect(!DockSplitStore.liveStores.contains(where: { $0 === store }))
    }
}
