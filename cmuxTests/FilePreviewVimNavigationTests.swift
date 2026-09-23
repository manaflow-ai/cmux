import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FilePreviewVimNavigationTests {
    @Test func configuredPreviewMovesWithoutEditing() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "filePreviewVimKeys")
        defer {
            if let previous { defaults.set(previous, forKey: "filePreviewVimKeys") }
            else { defaults.removeObject(forKey: "filePreviewVimKeys") }
        }
        defaults.set(true, forKey: "filePreviewVimKeys")
        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: "/tmp/cmux-vim-fixture.txt", startFileWatcher: false)
        defer { panel.close() }
        let view = SavingTextView.makeFilePreviewTextView()
        view.panel = panel
        view.string = "one two\nthree four\nfive six\n"
        let original = view.string
        for key in ["2", "j", "0", "w"] {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }
        #expect(view.string == original)
        #expect(view.selectedRange().location == 24)
        for key in ["i", "d", "d", "x", "p"] {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            )))
        }
        #expect(view.string == original)
    }
}
