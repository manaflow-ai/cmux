import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Per-surface tab colors must survive a session round-trip, and snapshots
/// written before the field existed must still restore (as uncolored tabs)
/// rather than failing the whole session decode.
@Suite(.serialized)
struct SurfaceTabColorPersistenceTests {
    private func snapshot(colorHex: String?) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: UUID(),
            type: .terminal,
            title: "api.ts",
            colorHex: colorHex
        )
    }

    @Test
    func colorSurvivesASessionRoundTrip() throws {
        let original = snapshot(colorHex: "#C0392B")
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)

        #expect(restored.colorHex == "#C0392B")
    }

    @Test
    func uncoloredSurfaceRestoresWithoutAColor() throws {
        let data = try JSONEncoder().encode(snapshot(colorHex: nil))
        let restored = try JSONDecoder().decode(SessionPanelSnapshot.self, from: data)

        #expect(restored.colorHex == nil)
    }

    /// A session written by a build that predates surface colors has no
    /// `colorHex` key at all. It must decode, not throw.
    @Test
    func snapshotWithoutColorKeyStillDecodes() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","type":"terminal","title":"legacy","isPinned":false}
        """
        let restored = try JSONDecoder().decode(
            SessionPanelSnapshot.self,
            from: Data(legacy.utf8)
        )

        #expect(restored.title == "legacy")
        #expect(restored.colorHex == nil)
    }

    /// The tab picker and the sidebar workspace picker read one palette, so a
    /// palette name resolves to the same hex on both paths.
    @Test
    func paletteNamesResolveToTheSharedWorkspacePalette() {
        let defaults = UserDefaults(suiteName: "SurfaceTabColorPersistenceTests.palette")!
        defaults.removePersistentDomain(forName: "SurfaceTabColorPersistenceTests.palette")
        defer { defaults.removePersistentDomain(forName: "SurfaceTabColorPersistenceTests.palette") }

        #expect(
            WorkspaceTabColorSettings.resolvedColorHex("Red", defaults: defaults)
                == WorkspaceTabColorSettings.defaultColorHex(named: "Red")
        )
        // Case-insensitive, and raw hex passes through normalized.
        #expect(WorkspaceTabColorSettings.resolvedColorHex("red", defaults: defaults) == "#C0392B")
        #expect(WorkspaceTabColorSettings.resolvedColorHex("#c0392b", defaults: defaults) == "#C0392B")
        #expect(WorkspaceTabColorSettings.resolvedColorHex("not-a-color", defaults: defaults) == nil)
    }
}
