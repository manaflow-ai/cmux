import CmuxiOSFeatureKit
import CmuxiOSPlatform
import Foundation
import Testing

@MainActor
@Suite("ShellRouter deferral")
struct ShellRouterTests {
    final class Recorder {
        var routes: [ShellRoute] = []
        var unrecognized: [URL] = []
    }

    private func makeRouter() -> (ShellRouter, Recorder) {
        let router = ShellRouter(parser: ShellRouteParser())
        let recorder = Recorder()
        router.install { recorder.routes.append($0) }
        router.onUnrecognized = { recorder.unrecognized.append($0) }
        return (router, recorder)
    }

    @Test func signedOutParksAndSignInDeliversOnce() {
        let (router, recorder) = makeRouter()
        #expect(router.open(URL(string: "cmux://feed/a")!) == .deferred)
        #expect(recorder.routes.isEmpty)
        router.setAccountReady(true)
        #expect(recorder.routes == [.feed(item: "a")])
        #expect(router.pending == nil)
        router.setAccountReady(false)
        router.setAccountReady(true)
        #expect(recorder.routes == [.feed(item: "a")])
    }

    @Test func newestParkedRouteWins() {
        let (router, recorder) = makeRouter()
        router.open(.feed(item: "old"))
        router.open(.hosts)
        router.setAccountReady(true)
        #expect(recorder.routes == [.hosts])
    }

    @Test func signOutDropsTheParkedRoute() {
        let (router, recorder) = makeRouter()
        router.setAccountReady(true)
        router.setAccountReady(false)
        router.open(.settings)
        #expect(router.pending == .settings)
        router.setAccountReady(true)
        #expect(recorder.routes == [.settings])
        router.setAccountReady(false)
        router.open(.hosts)
        router.setAccountReady(true)
        router.setAccountReady(false)
        #expect(router.pending == nil)
    }

    @Test func accountFreeRoutesDeliverWhileSignedOut() {
        let (router, recorder) = makeRouter()
        #expect(router.open(URL(string: "cmux://diagnostics")!) == .handled)
        #expect(recorder.routes == [.diagnostics])
    }

    @Test func readyRoutesDeliverAtOnce() {
        let (router, recorder) = makeRouter()
        router.setAccountReady(true)
        #expect(router.open(URL(string: "https://cmux.com/app/workspaces")!) == .handled)
        #expect(recorder.routes == [.workspaces])
    }

    @Test func routesBeforeInstallWaitForTheHandler() {
        let router = ShellRouter(parser: ShellRouteParser())
        router.setAccountReady(true)
        #expect(router.open(.hosts) == .deferred)
        let recorder = Recorder()
        router.install { recorder.routes.append($0) }
        #expect(recorder.routes == [.hosts])
    }

    @Test func unrecognizedLinksReport() {
        let (router, recorder) = makeRouter()
        let link = URL(string: "cmux://future-thing")!
        #expect(router.open(link) == .unrecognized)
        #expect(recorder.unrecognized == [link])
        #expect(router.pending == nil)
    }

    @Test func notificationPayloadsRoute() {
        let (router, recorder) = makeRouter()
        router.setAccountReady(true)
        let decoder = NotificationRouteDecoder(parser: router.parser)
        let byLink: [AnyHashable: Any] = ["cmux.route": "cmux://feed/item_1"]
        let byKeys: [AnyHashable: Any] = ["cmux.host": "mac-1", "cmux.workspace": "ws_2", "cmux.surface": "term_3"]
        let plain: [AnyHashable: Any] = ["aps": ["alert": "hi"]]
        let bad: [AnyHashable: Any] = ["cmux.host": "mac 1", "cmux.workspace": "ws_2"]
        #expect(router.openNotification(decoder.route(from: byLink)) == .handled)
        #expect(router.openNotification(decoder.route(from: byKeys)) == .handled)
        #expect(router.openNotification(decoder.route(from: plain)) == nil)
        #expect(router.openNotification(decoder.route(from: bad)) == nil)
        #expect(recorder.routes == [
            .feed(item: "item_1"),
            .workspace(host: HostID("mac-1"), workspace: "ws_2", surface: "term_3"),
        ])
    }
}
