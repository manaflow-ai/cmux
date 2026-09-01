import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Classification coverage for `fileExplorer.colorByFileType`.
///
/// Only the pure name → class mapping is exercised here. Resolving a class to
/// an `NSColor` reads the live Ghostty config and is main-actor bound, so it is
/// verified by eye rather than faked; what can go silently wrong without a test
/// is the table itself — a compound suffix shadowed by its tail, a directory
/// falling through to the extension table, a class pointing at the background
/// slot.
@Suite struct FileExplorerFileTypeColorTests {

    @Test func classifiesBySuffix() {
        #expect(FileExplorerFileTypeColor.kind(forName: "main.rs", isDirectory: false) == .source)
        #expect(FileExplorerFileTypeColor.kind(forName: "style.css", isDirectory: false) == .markup)
        #expect(FileExplorerFileTypeColor.kind(forName: "rows.parquet", isDirectory: false) == .data)
        #expect(FileExplorerFileTypeColor.kind(forName: "photo.png", isDirectory: false) == .media)
        #expect(FileExplorerFileTypeColor.kind(forName: "notes.md", isDirectory: false) == .document)
        #expect(FileExplorerFileTypeColor.kind(forName: "cmux.json", isDirectory: false) == .config)
    }

    @Test func compoundSuffixBeatsItsTail() {
        // `.gz` alone is also an archive, so this pair cannot catch a
        // regression on its own -- pair it with a compound whose tail
        // classifies differently.
        #expect(FileExplorerFileTypeColor.kind(forName: "bundle.tar.gz", isDirectory: false) == .archive)
        // `.map` is build junk; a file called `road.map` must not become
        // something else because an earlier dot was tried first.
        #expect(FileExplorerFileTypeColor.kind(forName: "v1.2.3.map", isDirectory: false) == .muted)
    }

    @Test func wholeNamesWinOverExtensions() {
        #expect(FileExplorerFileTypeColor.kind(forName: "Makefile", isDirectory: false) == .config)
        // README.md would be `.document` either way; package.json would be
        // `.config` either way. CMakeLists.txt is the one that proves the
        // filename table is consulted first: `.txt` alone is a document.
        #expect(FileExplorerFileTypeColor.kind(forName: "CMakeLists.txt", isDirectory: false) == .config)
        #expect(FileExplorerFileTypeColor.kind(forName: "notes.txt", isDirectory: false) == .document)
    }

    @Test func unknownNamesAreLeftAlone() {
        #expect(FileExplorerFileTypeColor.kind(forName: "nothing.qqq", isDirectory: false) == nil)
        #expect(FileExplorerFileTypeColor.kind(forName: "noextension", isDirectory: false) == nil)
    }

    @Test func directoriesResolveByNameAndNeverBySuffix() {
        #expect(FileExplorerFileTypeColor.kind(forName: "node_modules", isDirectory: true) == .muted)
        #expect(FileExplorerFileTypeColor.kind(forName: ".git", isDirectory: true) == .config)
        #expect(FileExplorerFileTypeColor.kind(forName: "src", isDirectory: true) == .directory)
        // A folder called assets.old is a folder, not a backup file.
        #expect(FileExplorerFileTypeColor.kind(forName: "assets.old", isDirectory: true) == .directory)
        #expect(FileExplorerFileTypeColor.kind(forName: "assets.old", isDirectory: false) == .muted)
    }

    @Test func symlinksOutrankEverything() {
        #expect(
            FileExplorerFileTypeColor.kind(forName: "main.rs", isDirectory: false, isSymlink: true)
                == .symlink
        )
    }

    @Test func everyClassMapsIntoThePaletteAndNoneTakesTheBackgroundSlot() {
        for kind in FileExplorerFileTypeColor.Kind.allCases {
            #expect(kind.paletteSlot > 0, "\(kind) would be invisible on the terminal background")
            #expect(kind.paletteSlot < 16, "\(kind) is outside the 16-colour ANSI palette")
        }
        // Two classes sharing a slot means two file kinds that cannot be told
        // apart, which defeats the point of the feature.
        let slots = FileExplorerFileTypeColor.Kind.allCases.map(\.paletteSlot)
        #expect(Set(slots).count == slots.count, "two classes share an ANSI slot")
    }

    @Test func tablesDoNotContradictEachOther() {
        // A name in both tables would resolve differently for a file and a
        // directory with the same spelling, which is confusing rather than
        // wrong -- but a duplicate inside one table is a straight typo.
        for (table, label) in [
            (FileExplorerFileTypeColor.extensions, "extensions"),
            (FileExplorerFileTypeColor.filenames, "filenames"),
            (FileExplorerFileTypeColor.directories, "directories"),
        ] {
            #expect(!table.isEmpty, "\(label) table is empty")
            for (name, _) in table {
                #expect(!name.contains(" "), "\(label) key \(name.debugDescription) has a space in it")
            }
        }
    }
}
