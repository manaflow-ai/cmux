import CmuxiOSFeatureKit
import CmuxiOSSFTPCore
import CmuxiOSViewersCore
import Foundation
import Testing

/// C13's file browser over the SFTP source: writes only where the source can.
@MainActor
struct SFTPFileBrowserTests {
    let host = HostID("ssh-box")

    private func model() async -> (FakeSFTPFileSystem, FileBrowserModel) {
        let system = FakeSFTPFileSystem()
        let directory = SFTPHostDirectory()
        await directory.register(FakeSFTPOpener(system: system), for: host)
        let source = SFTPViewerContentSource(directory: directory, transfer: SFTPFileTransfer(directory: directory))
        let target = ViewerTarget(hostID: host, hostName: "box", workspaceID: SFTPViewerContentSource.rootID, title: "box")
        return (system, FileBrowserModel(target: target, source: source))
    }

    @Test func browserWritesThroughTheSource() async throws {
        let (system, model) = await model()
        await model.load()
        #expect(model.path == "/home/me")
        #expect(model.operations != nil)
        #expect(await model.makeFolder(named: "  Projects ") == nil)
        #expect(model.entries.map(\.name) == ["Projects"])
        system.put("/home/me/a.txt", Data())
        await model.load()
        let file = try #require(model.entries.first { $0.name == "a.txt" })
        #expect(await model.rename(file, to: "b.txt") == nil)
        #expect(system.file("/home/me/b.txt") != nil)
        let renamed = try #require(model.entries.first { $0.name == "b.txt" })
        #expect(await model.delete(renamed) == nil)
        #expect(model.entries.map(\.name) == ["Projects"])
    }

    @Test func invalidNamesAreRefusedBeforeTheServer() async {
        let (system, model) = await model()
        await model.load()
        #expect(await model.makeFolder(named: "a/b") != nil)
        #expect(!system.isDirectory("/home/me/a/b"))
    }

    @Test func macSourcesDoNotWrite() {
        let target = ViewerTarget(hostID: host, hostName: "mac", workspaceID: "ws", title: "ws")
        #expect(FileBrowserModel(target: target, source: MockViewerContentSource()).operations == nil)
    }

    @Test(arguments: ["", "  ", ".", "..", "a/b", "tab\there", String(repeating: "x", count: 256)])
    func fileNameRuleRefuses(_ raw: String) {
        #expect(ViewerFileName(raw) == nil)
    }

    @Test func fileNameRuleTrims() {
        #expect(ViewerFileName("  notes.md \n")?.value == "notes.md")
        #expect(ViewerFileName("日本語.txt")?.value == "日本語.txt")
    }
}
