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
///
/// Resolution is asynchronous because it is filesystem work that must stay off the main thread, so
/// every assertion here waits on ``CustomSidebarWebReloadObserver/resolutionSettled()`` rather than
/// reading state the instant a request is made.
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

    /// An observer resolving through the same path `select` and `open` use, settled and ready to
    /// assert against.
    private func makeObserver(
        name: String,
        directory: URL,
        fallbackFileURL: URL? = nil
    ) async -> CustomSidebarWebReloadObserver {
        let observer = CustomSidebarWebReloadObserver(
            sidebarName: name,
            fallbackFileURL: fallbackFileURL
        ) { sidebarName in
            CmuxExtensionSidebarSelection.customSidebarFileURL(
                forName: sidebarName,
                sidebarsDirectory: directory
            )
        }
        await observer.resolutionSettled()
        return observer
    }

    @Test("a reload request bumps the token so an unchanged page still re-fetches")
    func reloadBumpsToken() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.reloadToken != before)
    }

    @Test("an unnamed reload request reaches web sidebars too, matching the interpreted filter")
    func unnamedReloadReachesWebSidebars() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: nil)
        await observer.resolutionSettled()
        #expect(observer.reloadToken != before)

        let afterNil = observer.reloadToken
        observer.requestReload(names: [])
        await observer.resolutionSettled()
        #expect(observer.reloadToken != afterNil)
    }

    @Test("a reload naming a different sidebar leaves this one alone")
    func namedReloadIsFiltered() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        let before = observer.reloadToken

        observer.requestReload(names: ["other"])
        await observer.resolutionSettled()

        #expect(observer.reloadToken == before)
    }

    // Adding board.swift beside board.html promotes the interpreted file. A surface still hosting
    // the page is now rendering the file that no longer wins.
    @Test("an interpreted file appearing demotes the web source on the next reload")
    func precedenceFlipToInterpreted() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        #expect(observer.webSource != nil)

        try write("Text(\"Swift\")", to: dir, as: "board.swift")
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.resolvedFileURL?.lastPathComponent == "board.swift")
        // No web source any more, so the mount falls back to the interpreter.
        #expect(observer.webSource == nil)
        #expect(observer.mountDecision == .interpreted(dir.appendingPathComponent("board.swift")))
    }

    @Test("deleting the interpreted file promotes the web source on the next reload")
    func precedenceFlipToWeb() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Text(\"Swift\")", to: dir, as: "board.swift")
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        #expect(observer.resolvedFileURL?.lastPathComponent == "board.swift")
        #expect(observer.webSource == nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("board.swift"))
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.resolvedFileURL?.lastPathComponent == "board.html")
        #expect(observer.webSource != nil)
    }

    @Test("a url sidebar follows its target changing behind the same file")
    func urlTargetChangeIsPickedUp() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")
        let observer = await makeObserver(name: "board", directory: dir)
        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:8787/")!))

        try write("http://127.0.0.1:9999/\n", to: dir, as: "board.url")
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:9999/")!))
    }

    @Test("deleting every file for a name resolves to nothing rather than the stale file")
    func deletedSidebarResolvesToNothing() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        #expect(observer.resolvedFileURL != nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("board.html"))
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.resolvedFileURL == nil)
        #expect(observer.webSource == nil)
        #expect(observer.mountDecision == .unavailable)
    }

    @Test("a posted reload notification drives the observer once started")
    func notificationDrivesObserver() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        observer.start()
        defer { observer.stop() }
        let before = observer.reloadToken

        NotificationCenter.default.post(
            name: .customSidebarReloadRequested,
            object: nil,
            userInfo: ["names": ["board"]]
        )
        await observer.resolutionSettled()

        #expect(observer.reloadToken != before)
    }

    @Test("a stopped observer ignores further notifications")
    func stoppedObserverIgnoresNotifications() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)
        observer.start()
        observer.stop()
        let before = observer.reloadToken

        NotificationCenter.default.post(
            name: .customSidebarReloadRequested,
            object: nil,
            userInfo: ["names": ["board"]]
        )
        await observer.resolutionSettled()

        #expect(observer.reloadToken == before)
    }

    // MARK: - Off the main thread

    /// The regression this file's async shape exists for.
    ///
    /// The observer used to resolve synchronously in `init` and `requestReload`, both on the main
    /// actor, and the mount decision was computed inside a SwiftUI view builder. For a `.url` sidebar
    /// that put a whole-file read on the main thread on every render pass — roughly once a second,
    /// forever, for as long as the sidebar is open.
    ///
    /// Asserted at the injected resolver seam itself: `Thread.isMainThread` directly records whether
    /// the filesystem lookup ran on the UI thread. That is the property, rather than a duration used
    /// as a proxy for it.
    ///
    /// The previous shape measured how long the main actor went unserviced while a deliberately
    /// enormous `.url` file was parsed, and compared best-of-three runs against a millisecond
    /// budget. That measures the app host's own display-link and layout work as much as this code,
    /// so it needed a fixture big enough to out-shout it and a threshold loose enough to survive a
    /// loaded CI box. The direct thread assertion needs neither.
    @Test("resolving a sidebar leaves the main actor free while the resolution is in flight")
    func resolutionDoesNotStallTheMainActor() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")

        let observed = ResolverObservation()
        let observer = CustomSidebarWebReloadObserver(sidebarName: "board") { _ in
            let ranOnMainThread = Thread.isMainThread
            let fileURL = CmuxExtensionSidebarSelection.customSidebarFileURL(
                forName: "board",
                sidebarsDirectory: dir
            )
            await observed.record(ranOnMainThread: ranOnMainThread)
            return fileURL
        }

        await observer.resolutionSettled()
        let resolverRanOnMainThread = await observed.ranOnMainThread()

        #expect(!resolverRanOnMainThread, "the resolver ran on the main thread")
        // The resolution really happened, so the ordering above is not about a no-op.
        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:8787/")!))
    }

    /// What thread the resolver used, read back once it has finished.
    private actor ResolverObservation {
        private var anyInvocationRanOnMainThread = false

        func record(ranOnMainThread: Bool) {
            anyInvocationRanOnMainThread = anyInvocationRanOnMainThread || ranOnMainThread
        }

        func ranOnMainThread() -> Bool {
            anyInvocationRanOnMainThread
        }
    }

    // MARK: - Mount decision

    /// A rejected `.url` must arrive at the surface as `.unavailable`, never as an absent decision a
    /// caller might fill in with the interpreter.
    @Test("a .url naming nothing loadable settles on unavailable")
    func rejectedURLSettlesUnavailable() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("file:///etc/passwd\n", to: dir, as: "board.url")
        let observer = await makeObserver(name: "board", directory: dir)

        #expect(observer.resolvedFileURL?.lastPathComponent == "board.url")
        #expect(observer.mountDecision == .unavailable)
        #expect(observer.webSource == nil)
    }

    /// A pane is opened on a file, so its first frame must be right without waiting for the
    /// filesystem — but only where the extension alone decides it. A `.url` fallback has to wait,
    /// because its bytes are what say whether the target is loadable at all.
    @Test("a pane's fallback file decides the first frame when its extension can")
    func fallbackDecidesFirstFrameForExtensionDecidedKinds() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("board.html")
        let observer = CustomSidebarWebReloadObserver(
            sidebarName: "board",
            fallbackFileURL: html
        ) { _ in nil }

        #expect(observer.mountDecision == .web(.document(html)))
    }

    @Test("a .url fallback file renders nothing until its target has been read")
    func urlFallbackWaitsForItsRead() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let observer = CustomSidebarWebReloadObserver(
            sidebarName: "board",
            fallbackFileURL: dir.appendingPathComponent("board.url")
        ) { _ in nil }

        #expect(observer.mountDecision == nil)
    }

    /// A sidebar saved in place is briefly absent from disk. A pane keeps its last known file across
    /// that moment; going `.unavailable` would blank the pane mid-edit.
    @Test("a pane keeps its last known file while the backing file is briefly gone")
    func fallbackSurvivesADisappearingFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("board.html")
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir, fallbackFileURL: html)
        #expect(observer.mountDecision == .web(.document(html)))

        try FileManager.default.removeItem(at: html)
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.resolvedFileURL == nil)
        #expect(observer.mountDecision == .web(.document(html)))
    }

    /// The rail has no fallback: it is switched away entirely when its sidebar stops resolving, so a
    /// last-known file there would outlive the selection that justified it.
    @Test("without a fallback, a name resolving to nothing is unavailable")
    func railHasNoLastKnownFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("<!doctype html>", to: dir, as: "board.html")
        let observer = await makeObserver(name: "board", directory: dir)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("board.html"))
        observer.requestReload(names: ["board"])
        await observer.resolutionSettled()

        #expect(observer.mountDecision == .unavailable)
    }

    /// Bumping the token before the new file is known would re-fetch the loser and then the winner:
    /// two loads and a visible flash of the old page for one `cmux sidebar reload`.
    @Test("the reload token and the re-resolved decision land together")
    func tokenAndDecisionLandTogether() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("http://127.0.0.1:8787/\n", to: dir, as: "board.url")
        let observer = await makeObserver(name: "board", directory: dir)
        let tokenBefore = observer.reloadToken

        try write("http://127.0.0.1:9999/\n", to: dir, as: "board.url")
        observer.requestReload(names: ["board"])
        // Mid-flight the old answer is still whole: neither half has moved yet.
        #expect(observer.reloadToken == tokenBefore)
        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:8787/")!))

        await observer.resolutionSettled()

        #expect(observer.reloadToken != tokenBefore)
        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:9999/")!))
    }

    /// Requests are served in order by one consumer, so a burst leaves the newest answer standing
    /// rather than whichever filesystem read happened to finish last.
    @Test("a burst of reloads settles on the newest state")
    func burstOfReloadsSettlesOnTheNewestState() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("http://127.0.0.1:8000/\n", to: dir, as: "board.url")
        let observer = await makeObserver(name: "board", directory: dir)

        for port in 8001...8005 {
            try write("http://127.0.0.1:\(port)/\n", to: dir, as: "board.url")
            observer.requestReload(names: ["board"])
        }
        await observer.resolutionSettled()

        #expect(observer.webSource == .remote(URL(string: "http://127.0.0.1:8005/")!))
    }
}
