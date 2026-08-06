import CmuxFoundation
import CmuxSidebar
import CmuxSwiftRenderUI
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// `cmux sidebar reload` reaching a hosted web sidebar, and following a precedence change.
///
/// Interpreted sidebars answer the reload notification through `CustomSidebarModel`; a web sidebar
/// has no model, so nothing was listening and the command silently did nothing. Re-resolution is the
/// other half: a surface that captured its file once keeps rendering the loser after the winner
/// changes, which the user experiences as the same "reload did nothing".
@Suite("Custom sidebar web reload observer")
@MainActor
struct CustomSidebarWebReloadObserverTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-reload-obs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to directory: URL, as name: String) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    /// An observer resolving through the same path `select` and `open` use.
    private func makeObserver(name: String, directory: URL) -> CustomSidebarWebReloadObserver {
        CustomSidebarWebReloadObserver(sidebarName: name) { sidebarName in
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forName: sidebarName,
                sidebarsDirectory: directory
            )
        }
    }

    @Test("a reload request bumps the token so an unchanged page still re-fetches")
    func reloadBumpsToken() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: ["board"])

        #expect(observer.reloadToken != before)
    }

    @Test("an unnamed reload request reaches web sidebars too, matching the interpreted filter")
    func unnamedReloadReachesWebSidebars() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: nil)
        #expect(observer.reloadToken != before)

        let afterNil = observer.reloadToken
        observer.requestReload(names: [])
        #expect(observer.reloadToken != afterNil)
    }

    @Test("a reload naming a different sidebar leaves this one alone")
    func namedReloadIsFiltered() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: ["other"])

        #expect(observer.reloadToken == before)
    }

    // Adding board.swift beside board.html promotes the interpreted file. A surface still hosting
    // the page is now rendering the file that no longer wins.
    @Test("an interpreted file appearing demotes the web source on the next reload")
    func precedenceFlipToInterpreted() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        #expect(observer.webSource != nil)

        try write("Text(\"Swift\")", to: dir, as: "board.swift")
        observer.requestReload(names: ["board"])

        #expect(observer.resolvedFileURL?.lastPathComponent == "board.swift")
        // No web source any more, so the mount falls back to the interpreter.
        #expect(observer.webSource == nil)
    }

    @Test("deleting the interpreted file promotes the web source on the next reload")
    func precedenceFlipToWeb() throws {
        let dir = try directory()
        try write("Text(\"Swift\")", to: dir, as: "board.swift")
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        #expect(observer.resolvedFileURL?.lastPathComponent == "board.swift")
        #expect(observer.webSource == nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("board.swift"))
        observer.requestReload(names: ["board"])

        #expect(observer.resolvedFileURL?.lastPathComponent == "board.html")
        #expect(observer.webSource != nil)
    }

    @Test("a url sidebar follows its target changing behind the same file")
    func urlTargetChangeIsPickedUp() throws {
        let dir = try directory()
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")
        let observer = makeObserver(name: "board", directory: dir)
        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:8787/")!))

        try write("http://127.0.0.1:9999/\n", to: dir, as: "board.url")
        observer.requestReload(names: ["board"])

        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:9999/")!))
    }

    @Test("deleting every file for a name resolves to nothing rather than the stale file")
    func deletedSidebarResolvesToNothing() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        #expect(observer.resolvedFileURL != nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("board.html"))
        observer.requestReload(names: ["board"])

        #expect(observer.resolvedFileURL == nil)
        #expect(observer.webSource == nil)
    }

    @Test("a posted reload notification drives the observer once started")
    func notificationDrivesObserver() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        observer.start()
        defer { observer.stop() }
        let before = observer.reloadToken

        NotificationCenter.default.post(
            name: .customSidebarReloadRequested,
            object: nil,
            userInfo: ["names": ["board"]]
        )

        #expect(observer.reloadToken != before)
    }

    @Test("a stopped observer ignores further notifications")
    func stoppedObserverIgnoresNotifications() throws {
        let dir = try directory()
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = makeObserver(name: "board", directory: dir)
        observer.start()
        observer.stop()
        let before = observer.reloadToken

        NotificationCenter.default.post(
            name: .customSidebarReloadRequested,
            object: nil,
            userInfo: ["names": ["board"]]
        )

        #expect(observer.reloadToken == before)
    }
}
