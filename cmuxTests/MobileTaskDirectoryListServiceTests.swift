import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileTaskDirectoryListServiceTests {
    @Test func advertisesAndDispatchesDirectoryBrowsing() async {
        #expect(MobileHostService.mobileHostCapabilities.contains("workspace.directory_browse.v1"))

        let request = MobileHostRPCRequest(
            id: "directory-list",
            method: "mobile.directory.list",
            params: [
                "path": "relative",
                "offset": 0,
                "limit": 50,
            ],
            auth: nil
        )
        let result = await TerminalController.shared.mobileHostHandleRPC(request)
        guard case let .failure(error) = result else {
            return #expect(Bool(false), "A relative directory path must be rejected")
        }
        #expect(error.code == "invalid_params")
    }

    @Test func includesHiddenPackagesAndDirectorySymlinksWithExactPagination() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = MobileTaskDirectoryListService(
            fileManager: .default,
            homeDirectory: fixture.root
        )

        let first = try await service.list(path: "~", offset: 0, limit: 2)

        #expect(first.currentPath == fixture.root.standardizedFileURL.path)
        #expect(first.parentPath == fixture.base.standardizedFileURL.path)
        #expect(first.entries.map(\.name) == [".hidden", "Bundle.app"])
        #expect(first.entries[0].isHidden)
        #expect(first.entries[1].isPackage)
        #expect(first.totalCount == 4)
        #expect(first.nextOffset == 2)

        let second = try await service.list(path: "~", offset: 2, limit: 2)

        #expect(second.entries.map(\.name) == ["Zebra", "linked"])
        #expect(second.entries.last?.isSymbolicLink == true)
        #expect(second.nextOffset == nil)
    }

    @Test func clampsStaleOffsetToExactEndWithoutLosingPaginationMetadata() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = MobileTaskDirectoryListService(
            fileManager: .default,
            homeDirectory: fixture.root
        )

        let page = try await service.list(path: fixture.root.path, offset: 99, limit: 10)

        #expect(page.offset == page.totalCount)
        #expect(page.entries.isEmpty)
        #expect(page.nextOffset == nil)
    }

    @Test func distinguishesMissingPathsFromFiles() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let service = MobileTaskDirectoryListService(
            fileManager: .default,
            homeDirectory: fixture.root
        )

        await #expect(throws: MobileTaskDirectoryListServiceError.notFound) {
            try await service.list(
                path: fixture.root.appendingPathComponent("missing").path,
                offset: 0,
                limit: 10
            )
        }
        await #expect(throws: MobileTaskDirectoryListServiceError.notDirectory) {
            try await service.list(path: fixture.file.path, offset: 0, limit: 10)
        }
    }

    @Test func surfacesUnreadableDirectoryInsteadOfReturningAnEmptyPage() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let locked = fixture.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: locked.path
            )
        }
        let service = MobileTaskDirectoryListService(
            fileManager: .default,
            homeDirectory: fixture.root
        )

        do {
            _ = try await service.list(path: locked.path, offset: 0, limit: 10)
            #expect(Bool(false), "An unreadable directory must not look empty")
        } catch let error as MobileTaskDirectoryListServiceError {
            #expect(error == .unreadable || error == .permissionDenied)
        }
    }

    private static func makeFixture() throws -> (
        base: URL,
        root: URL,
        file: URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-directory-list-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("home", isDirectory: true)
        let external = base.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for name in [".hidden", "Bundle.app", "Zebra"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: external
        )
        let file = root.appendingPathComponent("plain.txt", isDirectory: false)
        try Data("not a directory".utf8).write(to: file)
        return (base, root, file)
    }
}
