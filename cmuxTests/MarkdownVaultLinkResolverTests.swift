import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Unit coverage for Obsidian-vault-aware wiki-link resolution.
/// `resolveVaultWikiLink` finds a note by name anywhere under the vault root
/// (nearest ancestor containing `.obsidian`), which is how `[[Note]]` resolves
/// when the target lives in a different folder than the open file.
@Suite
struct MarkdownVaultLinkResolverTests {
    private func makeVault() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-vault-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        for rel in ["01 - Current Work", "03 - Directory", "Meeting Notes/2026", "deep/nested"] {
            try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        func write(_ rel: String) throws {
            try "# note".write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try write("01 - Current Work/Index.md")
        try write("03 - Directory/Jodi Schatz.md")
        try write("Meeting Notes/2026/Standup.md")
        try write("Ambiguous.md")
        try write("deep/nested/Ambiguous.md")
        // Canonicalize so `/var` vs `/private/var` symlink forms don't make
        // path equality flaky between the resolver and the expectations.
        return root.resolvingSymlinksInPath()
    }

    /// macOS special-cases `/var`, `/tmp`, `/etc`: `resolvingSymlinksInPath`
    /// leaves them as-is while `FileManager`'s directory enumerator yields the
    /// `/private/…` form. Normalize both so absolute-path equality is stable.
    private func canonical(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.hasPrefix("/private/var") ? String(path.dropFirst("/private".count)) : path
    }

    @Test
    func resolvesNoteInADifferentFolderByName() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let source = vault.appendingPathComponent("01 - Current Work/Index.md").path

        let resolved = MarkdownPanelFileLinkResolver.resolveVaultWikiLink(
            rawPath: "Jodi Schatz.md",
            relativeToMarkdownFile: source
        )
        #expect(canonical(resolved) == canonical(vault.appendingPathComponent("03 - Directory/Jodi Schatz.md").path))
    }

    @Test
    func prefersExactRelativeSubpathOverBareName() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let source = vault.appendingPathComponent("01 - Current Work/Index.md").path

        let resolved = MarkdownPanelFileLinkResolver.resolveVaultWikiLink(
            rawPath: "Meeting Notes/2026/Standup.md",
            relativeToMarkdownFile: source
        )
        #expect(canonical(resolved) == canonical(vault.appendingPathComponent("Meeting Notes/2026/Standup.md").path))
    }

    @Test
    func prefersShallowestMatchWhenNameIsAmbiguous() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let source = vault.appendingPathComponent("01 - Current Work/Index.md").path

        let resolved = MarkdownPanelFileLinkResolver.resolveVaultWikiLink(
            rawPath: "Ambiguous.md",
            relativeToMarkdownFile: source
        )
        #expect(canonical(resolved) == canonical(vault.appendingPathComponent("Ambiguous.md").path))
    }

    @Test
    func returnsNilForMissingNote() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let source = vault.appendingPathComponent("01 - Current Work/Index.md").path

        let resolved = MarkdownPanelFileLinkResolver.resolveVaultWikiLink(
            rawPath: "Nonexistent Note.md",
            relativeToMarkdownFile: source
        )
        #expect(resolved == nil)
    }

    @Test
    func returnsNilOutsideAnObsidianVault() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cmux-plain-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "# a".write(to: dir.appendingPathComponent("Target.md"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("sub/Open.md").path
        try "# open".write(toFile: source, atomically: true, encoding: .utf8)

        // No `.obsidian` ancestor: vault resolution declines so non-vault
        // markdown keeps sibling-only behavior.
        #expect(MarkdownPanelFileLinkResolver.vaultRoot(forMarkdownFile: source) == nil)
        #expect(MarkdownPanelFileLinkResolver.resolveVaultWikiLink(
            rawPath: "Target.md",
            relativeToMarkdownFile: source
        ) == nil)
    }

    @Test
    func detectsVaultRootFromNestedFile() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let source = vault.appendingPathComponent("Meeting Notes/2026/Standup.md").path
        #expect(MarkdownPanelFileLinkResolver.vaultRoot(forMarkdownFile: source) == vault.path)
    }
}
