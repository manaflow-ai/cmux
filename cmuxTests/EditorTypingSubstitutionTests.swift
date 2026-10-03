import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux's text editors must save exactly the bytes that were typed
/// (https://github.com/manaflow-ai/cmux/issues/16738).
///
/// `NSTextView` follows the macOS text input settings ("Use smart quotes and
/// dashes", text replacement, "Correct spelling automatically", "Add period
/// with double-space"), which are on by default. In an editor they rewrite
/// `"` into `“`/`”`, `--` into `—` and so on, which corrupted
/// `.claude/settings.json` and crashed Claude Code. The same applies to any
/// file, so this saves a plain `.ts` file rather than JSON.
@MainActor
@Suite("Editors save typed text verbatim", .serialized)
struct EditorTypingSubstitutionTests {
    /// Straight quotes, `--`, a URL, tabs, a double space and a common typo:
    /// each one is a target of a macOS typing substitution.
    static let typedSource = """
    \t// editor fixture -- keep "straight" quotes and 'single' quotes  as typed
    \tconst issue = "https://github.com/manaflow-ai/cmux/issues/16738";
    \t\tconst command = "cmux --notify 'done' --- teh end";
    const tab = '\t';

    """

    @Test("file editor saves a typed .ts file byte-for-byte")
    func fileEditorSavesTypedTextVerbatim() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-editor-verbatim-\(UUID().uuidString).ts")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL)

        try await Self.withSystemSubstitutionsEnabled {
            let panel = FilePreviewPanel(
                workspaceId: UUID(),
                filePath: fileURL.path,
                startFileWatcher: false
            )
            defer { panel.close() }
            await panel.loadTextContent().value

            let textView = SavingTextView.makeFilePreviewTextView()
            Self.type(Self.typedSource, into: textView)
            // The editor coordinator forwards every text change like this.
            panel.updateTextContent(textView.string)

            let save = try #require(panel.saveTextContent())
            await save.value
        }

        let saved = try Data(contentsOf: fileURL)
        #expect(
            saved == Data(Self.typedSource.utf8),
            "saved file differs from typed text: \(String(decoding: saved, as: UTF8.self).debugDescription)"
        )
    }

    /// Types `text` one character at a time, the way keyboard input arrives,
    /// then runs AppKit's text checking the way it does after typing pauses.
    static func type(_ text: String, into textView: NSTextView) {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        for character in text {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
        textView.checkTextInDocument(nil)
    }

    /// The `UserDefaults` keys behind the macOS text input settings.
    static let systemSubstitutionDefaultsKeys = [
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticDashSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
    ]

    /// Runs `body` as on a Mac with every text input substitution turned on,
    /// then restores the previous values.
    static func withSystemSubstitutionsEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let savedValues = systemSubstitutionDefaultsKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(systemSubstitutionDefaultsKeys, savedValues) {
                defaults.set(value, forKey: key)
            }
        }
        for key in systemSubstitutionDefaultsKeys {
            defaults.set(true, forKey: key)
        }
        try await body()
    }
}
