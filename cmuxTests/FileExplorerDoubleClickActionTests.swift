import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-logic coverage for the file explorer double-click action setting
/// (`fileExplorer.doubleClickAction`). Verifies parse/validation (unknown
/// values fall back to `preview`), UserDefaults round-tripping, and the
/// action-resolution function that maps a configured action plus the
/// preferred-editor availability to the concrete open behavior — including the
/// `preferredEditor` → `defaultEditor` fallback when no command is configured.
///
/// The NSOutlineView / NSTableView gesture wiring itself (doubleAction targets)
/// is AppKit-bound and not cleanly unit-testable; it is exercised manually and
/// not faked here.
@Suite struct FileExplorerDoubleClickActionTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-file-explorer-double-click-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Parse / validation

    @Test func defaultIsPreview() {
        #expect(FileExplorerDoubleClickActionSettings.defaultValue == .preview)
    }

    @Test func parsesEachKnownRawValue() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preview") == .preview)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "defaultEditor") == .defaultEditor)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preferredEditor") == .preferredEditor)
    }

    @Test func nilRawValueFallsBackToPreview() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: nil) == .preview)
    }

    @Test func unknownRawValueFallsBackToPreview() {
        for raw in ["", "  ", "Preview", "PREVIEW", "editor", "default", "preferred", "garbage"] {
            #expect(
                FileExplorerDoubleClickActionSettings.action(forRawValue: raw) == .preview,
                "unknown raw value \(raw.debugDescription) should fall back to preview"
            )
        }
    }

    @Test func rawValuesMatchConfigSchema() {
        #expect(FileExplorerDoubleClickAction.preview.rawValue == "preview")
        #expect(FileExplorerDoubleClickAction.defaultEditor.rawValue == "defaultEditor")
        #expect(FileExplorerDoubleClickAction.preferredEditor.rawValue == "preferredEditor")
        #expect(
            FileExplorerDoubleClickAction.allCases == [.preview, .defaultEditor, .preferredEditor]
        )
    }

    // MARK: - UserDefaults round-trip

    @Test func resolvedActionDefaultsToPreviewWhenUnset() {
        let defaults = makeDefaults()
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    @Test func resolvedActionReadsStoredValue() {
        for action in FileExplorerDoubleClickAction.allCases {
            let defaults = makeDefaults()
            FileExplorerDoubleClickActionSettings.setAction(
                action,
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )
            #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == action)
        }
    }

    @Test func resolvedActionFallsBackForCorruptedStoredValue() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-action", forKey: FileExplorerDoubleClickActionSettings.key)
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    // MARK: - Action resolution (setting + preferred-editor availability)

    @Test func previewResolvesToPreviewRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .preview,
                    hasPreferredEditorCommand: hasEditor
                ) == .preview
            )
        }
    }

    @Test func defaultEditorResolvesToDefaultEditorRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .defaultEditor,
                    hasPreferredEditorCommand: hasEditor
                ) == .defaultEditor
            )
        }
    }

    @Test func preferredEditorResolvesToPreferredEditorWhenCommandConfigured() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: true
            ) == .preferredEditor
        )
    }

    @Test func preferredEditorFallsBackToDefaultEditorWhenNoCommand() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: false
            ) == .defaultEditor
        )
    }
}

@Suite struct FileExplorerSortSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-file-explorer-sort-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func defaultSortIsNameAscending() {
        #expect(FileExplorerSortSettings.defaultValue == FileExplorerSortOptions(key: .name, order: .ascending))
    }

    @Test func parsesEachKnownSortKeyRawValue() {
        #expect(FileExplorerSortSettings.sortKey(forRawValue: "name") == .name)
        #expect(FileExplorerSortSettings.sortKey(forRawValue: "dateCreated") == .dateCreated)
        #expect(FileExplorerSortSettings.sortKey(forRawValue: "dateModified") == .dateModified)
    }

    @Test func parsesEachKnownSortOrderRawValue() {
        #expect(FileExplorerSortSettings.sortOrder(forRawValue: "ascending") == .ascending)
        #expect(FileExplorerSortSettings.sortOrder(forRawValue: "descending") == .descending)
    }

    @Test func unknownSortValuesFallBackToDefaults() {
        for raw in [nil, "", "modified", "date-created", "DESC", "newest"] {
            #expect(FileExplorerSortSettings.sortKey(forRawValue: raw) == .name)
            #expect(FileExplorerSortSettings.sortOrder(forRawValue: raw) == .ascending)
        }
    }

    @Test func rawValuesMatchConfigSchema() {
        #expect(FileExplorerSortKey.allCases.map(\.rawValue) == ["name", "dateCreated", "dateModified"])
        #expect(FileExplorerSortOrder.allCases.map(\.rawValue) == ["ascending", "descending"])
    }

    @Test func resolvedOptionsRoundTripThroughUserDefaults() {
        let defaults = makeDefaults()
        let options = FileExplorerSortOptions(key: .dateModified, order: .descending)

        FileExplorerSortSettings.setOptions(
            options,
            defaults: defaults,
            notificationCenter: NotificationCenter()
        )

        #expect(FileExplorerSortSettings.resolvedOptions(defaults: defaults) == options)
    }
}
