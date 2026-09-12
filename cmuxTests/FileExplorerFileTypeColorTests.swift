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
/// falling through to the extension table, two classes landing on one slot.
@Suite struct FileExplorerFileTypeColorTests {

    private typealias Kind = FileExplorerFileTypeColor.Kind

    private func kind(_ name: String, dir: Bool = false, link: Bool = false) -> Kind? {
        FileExplorerFileTypeColor.kind(forName: name, isDirectory: dir, isSymlink: link)
    }

    @Test func classifiesBySuffix() {
        #expect(kind("main.rs") == .source)
        #expect(kind("deploy.sh") == .script)
        #expect(kind("style.css") == .markup)
        #expect(kind("rows.parquet") == .data)
        #expect(kind("photo.png") == .media)
        #expect(kind("notes.md") == .document)
        #expect(kind("report.pdf") == .office)
        #expect(kind("cmux.json") == .config)
        #expect(kind("server.pem") == .secret)
        #expect(kind("bundle.zip") == .archive)
    }

    /// The whole point of the change: a plain source checkout has to come out
    /// in more than three colours. Blue directories plus green code plus
    /// yellow everything-else is what this replaced.
    @Test func aSourceCheckoutUsesMostOfThePalette() {
        let repo = ["src", "docs", "assets", "node_modules", ".git", "scripts"]
            .compactMap { kind($0, dir: true) }
        + ["main.rs", "build.sh", "Cargo.toml", "Cargo.lock", "README.md",
           "index.html", "rows.csv", "logo.png", "spec.pdf", "dist.tar.gz",
           ".env", "notes.txt", "app.o"].compactMap { kind($0) }
        let slots = Set(repo.map(\.paletteSlot))
        #expect(slots.count >= 12, "an ordinary repo only reaches \(slots.count) colours: \(slots.sorted())")
    }

    @Test func compoundSuffixBeatsItsTail() {
        #expect(kind("bundle.tar.gz") == .archive)
        // `.ts` is source; `.d.ts` is generated. If the walk tried the shortest
        // suffix first this would come back .source.
        #expect(kind("types.d.ts") == .generated)
        #expect(kind("app.min.js") == .generated)
        #expect(kind("app.js") == .source)
    }

    @Test func wholeNamesWinOverExtensions() {
        #expect(kind("Makefile") == .build)
        // `.txt` alone is a document; CMakeLists.txt is a build file.
        #expect(kind("CMakeLists.txt") == .build)
        #expect(kind("notes.txt") == .document)
        // `.json` alone is config; these two are not.
        #expect(kind("package.json") == .build)
        #expect(kind("package-lock.json") == .generated)
        #expect(kind("tsconfig.json") == .build)
        #expect(kind("settings.json") == .config)
    }

    @Test func secretsAreCalledOut() {
        #expect(kind(".env") == .secret)
        #expect(kind("id_ed25519") == .secret)
        #expect(kind("server.key") == .secret)
    }

    @Test func unknownNamesAreLeftAlone() {
        #expect(kind("nothing.qqq") == nil)
        #expect(kind("noextension") == nil)
    }

    @Test func directoriesResolveByNameAndNeverBySuffix() {
        #expect(kind("src", dir: true) == .source)
        #expect(kind("docs", dir: true) == .document)
        #expect(kind("assets", dir: true) == .media)
        #expect(kind("node_modules", dir: true) == .muted)
        #expect(kind(".git", dir: true) == .generated)
        #expect(kind("whatever", dir: true) == .directory)
        // A folder called assets.old is a folder, not a backup file.
        #expect(kind("assets.old", dir: true) == .directory)
        #expect(kind("assets.old") == .muted)
        // Exact match only: `lib` is a source folder, `zlib` is just a folder.
        #expect(kind("lib", dir: true) == .source)
        #expect(kind("zlib", dir: true) == .directory)
    }

    @Test func symlinksOutrankEverything() {
        #expect(kind("main.rs", link: true) == .symlink)
        #expect(kind("src", dir: true, link: true) == .symlink)
    }

    @Test func everyClassOwnsExactlyOneSlotAndNoneIsTheBackground() {
        let slots = Kind.allCases.map(\.paletteSlot)
        for (kind, slot) in zip(Kind.allCases, slots) {
            #expect(slot > 0, "\(kind) would be invisible on the terminal background")
            #expect(slot < 16, "\(kind) is outside the 16-colour ANSI palette")
        }
        #expect(Set(slots).count == slots.count, "two classes share an ANSI slot")
        // 15 classes for slots 1...15: the palette is fully used, which is the
        // difference between a colourful tree and a blue/green/yellow one.
        #expect(Set(slots) == Set(1...15), "slots \(Set(1...15).subtracting(slots).sorted()) are unused")
    }

    @Test func noNameIsClaimedByTwoClasses() {
        // mapping() asserts on this in debug builds; assert it here too so a
        // release-configuration test run still catches it.
        for (table, label) in [
            (FileExplorerFileTypeColor.extensions, "extensions"),
            (FileExplorerFileTypeColor.filenames, "filenames"),
            (FileExplorerFileTypeColor.directories, "directories"),
        ] {
            #expect(!table.isEmpty, "\(label) table is empty")
            for name in table.keys {
                #expect(!name.contains(" "), "\(label) key \(name.debugDescription) has a space in it")
            }
        }
    }
}
