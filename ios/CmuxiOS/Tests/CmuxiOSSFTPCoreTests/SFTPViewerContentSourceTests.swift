import CmuxiOSFeatureKit
@testable import CmuxiOSSFTPCore
import CmuxiOSViewersCore
import CmuxMobileWire
import Foundation
import Testing

struct SFTPViewerContentSourceTests {
    let host = HostID("ssh-box")

    private func setUp() async -> (FakeSFTPFileSystem, FakeSFTPOpener, SFTPViewerContentSource) {
        let system = FakeSFTPFileSystem()
        let opener = FakeSFTPOpener(system: system)
        let directory = SFTPHostDirectory()
        await directory.register(opener, for: host)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-viewer-\(UUID().uuidString)")
        let source = SFTPViewerContentSource(directory: directory, transfer: SFTPFileTransfer(directory: directory), cacheDirectory: cache)
        return (system, opener, source)
    }

    @Test func theOneRootIsTheLoginDirectory() async throws {
        let (_, _, source) = await setUp()
        #expect(try await source.roots(host: host) == [FilesRoot(id: SFTPViewerContentSource.rootID, name: "me", path: "/home/me", writable: true)])
    }

    @Test func listingMapsKindsSizesAndDates() async throws {
        let (system, _, source) = await setUp()
        system.put("/home/me/a.md", Data("# hi".utf8))
        system.addDirectory("/home/me/src")
        system.addLink("/home/me/link")
        let result = try await source.list(host: host, path: "/home/me", after: nil)
        #expect(result.entries.map(\.name) == ["a.md", "link", "src"])
        #expect(result.entries.map(\.kind) == [.file, .symlink, .dir])
        #expect(result.entries[0].size == 4)
        #expect(result.entries[0].modifiedAt == 1_700_000_000_000)
        #expect(result.next == nil)
        #expect(try await source.list(host: host, path: "/home/me", after: "a.md").entries.isEmpty)
    }

    @Test func gitReadsSayNotARepository() async throws {
        let (_, _, source) = await setUp()
        await #expect(throws: ViewerSourceError.notARepository) { try await source.status(host: host, path: "/home/me") }
    }

    @Test func fetchDownloadsIntoTheCache() async throws {
        let (system, _, source) = await setUp()
        system.put("/home/me/readme.txt", Data("text".utf8))
        let url = try await source.fetch(host: host, path: "/home/me/readme.txt", size: 4)
        #expect(url.lastPathComponent == "readme.txt")
        #expect(try Data(contentsOf: url) == Data("text".utf8))
    }

    @Test func writesReachTheServer() async throws {
        let (system, _, source) = await setUp()
        try await source.makeDirectory(host: host, path: "/home/me/new")
        #expect(system.isDirectory("/home/me/new"))
        system.put("/home/me/f", Data())
        try await source.rename(host: host, from: "/home/me/f", to: "/home/me/g")
        #expect(system.file("/home/me/g") != nil)
        try await source.remove(host: host, path: "/home/me/g", isDirectory: false)
        try await source.remove(host: host, path: "/home/me/new", isDirectory: true)
        #expect(system.file("/home/me/g") == nil)
        #expect(!system.isDirectory("/home/me/new"))
    }

    @Test func errorsUseViewerTerms() async throws {
        let (_, _, source) = await setUp()
        await #expect(throws: ViewerSourceError.notFound) { try await source.list(host: host, path: "/missing", after: nil) }
        await #expect(throws: ViewerSourceError.failed("exists")) { try await source.makeDirectory(host: host, path: "/home/me") }
        let unregistered = SFTPViewerContentSource(directory: SFTPHostDirectory(), transfer: SFTPFileTransfer(directory: SFTPHostDirectory()))
        await #expect(throws: ViewerSourceError.noConnection) { try await unregistered.roots(host: host) }
    }

    @Test func closingTheHostClosesItsSession() async throws {
        let system = FakeSFTPFileSystem()
        let opener = FakeSFTPOpener(system: system)
        let directory = SFTPHostDirectory()
        await directory.register(opener, for: host)
        await directory.close(host)
        #expect(await opener.closed)
        #expect(await !directory.isRegistered(host))
    }

    @Test func aStaleLeaseDoesNotCloseANewerSession() async throws {
        let directory = SFTPHostDirectory()
        let first = FakeSFTPOpener(system: FakeSFTPFileSystem())
        let second = FakeSFTPOpener(system: FakeSFTPFileSystem())
        let old = await directory.register(first, for: host)
        let current = await directory.register(second, for: host)
        #expect(await first.closed)
        await directory.release(host, lease: old)
        #expect(await !second.closed)
        await directory.release(host, lease: current)
        #expect(await second.closed)
    }
}
