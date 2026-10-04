import Foundation
@testable import LocalAppSpike
import Testing
import WebKit

/// The functional questions for WebKit, each answered by a run:
/// - can a private WKContentWorld open a WebSocket;
/// - do page-world prototype patches reach it;
/// - what the page world can see of the private world through the shared DOM;
/// - does a page-world spy see the token today (direct), with A, and with B.
@MainActor @Suite(.serialized) struct IsolationProbeTests {
    static let token = String(repeating: "ab12", count: 16)

    struct Outcome {
        var spyCaughtToken: Bool
        var spySawFrames: Bool
        var serverGotToken: Bool
        var origin: String?
        var pageProbe: String
    }

    func run(_ mode: BenchPage.Mode) async throws -> (Outcome, String?) {
        let server = SpikeServer()
        try await server.start()
        defer { server.stop() }
        let page = BenchPage(mode: mode, spy: true)
        defer { page.close() }
        await page.load()
        var isolatedProbe: String?
        if let isolated = page.isolated {
            isolatedProbe = try await isolated.run("return (" + SpikeJS.isolatedProbe + "\n);") as? String
        }
        try await page.connect(server.url, token: Self.token)
        _ = await server.stream(to: mode.rawValue, count: 50, window: 50)
        let seen = try await page.page("return JSON.stringify(window.__spySeen);") as? String ?? ""
        let probe = try await page.page("return window.__probe();") as? String ?? ""
        let first = server.first(of: mode.rawValue)
        let outcome = Outcome(
            spyCaughtToken: seen.contains(Self.token), spySawFrames: seen.contains("agent_message_chunk"),
            serverGotToken: first.frame?.contains(Self.token) ?? false, origin: first.origin, pageProbe: probe)
        print("SPIKE-PROBE webkit mode=\(mode.rawValue) spyCaughtToken=\(outcome.spyCaughtToken) spySawFrames=\(outcome.spySawFrames) serverGotToken=\(outcome.serverGotToken) origin=\(outcome.origin ?? "none") page=\(probe) isolated=\(isolatedProbe ?? "-")")
        return (outcome, isolatedProbe)
    }

    @Test func directLeaksTheTokenToThePageWorld() async throws {
        let (outcome, _) = try await run(.direct)
        #expect(outcome.serverGotToken)
        #expect(outcome.spyCaughtToken, "the attack must work today, or the spy proves nothing")
    }

    @Test func isolatedWorldOpensTheSocketAndHidesTheToken() async throws {
        let (outcome, isolated) = try await run(.isolated)
        #expect(outcome.serverGotToken, "the private world's socket reached the server with the token")
        #expect(outcome.spySawFrames, "the spy does see the frames the page receives")
        #expect(!outcome.spyCaughtToken)
        #expect(outcome.origin == BenchPage.pageOrigin, "the private world's socket carries the page's Origin")
        let iso = try #require(isolated.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(iso["wsSendNative"] as? Bool == true)
        #expect(iso["jsonNative"] as? Bool == true)
        #expect(iso["portNative"] as? Bool == true)
        #expect(iso["protoSetter"] as? Bool == false)
        #expect(iso["spyVisible"] as? String == "undefined")
        let page = try #require(try? JSONSerialization.jsonObject(with: Data(outcome.pageProbe.utf8)) as? [String: Any])
        #expect(page["connectVisible"] as? String == "undefined")
        #expect(page["isoGlobal"] as? String == "undefined")
        #expect(page["isoExpando"] as? String == "undefined")
        // Recorded, not asserted: DOM attributes are shared; CustomEvent.detail across worlds.
    }

    @Test func nativeRelayHidesTheToken() async throws {
        let (outcome, _) = try await run(.relay)
        #expect(outcome.serverGotToken)
        #expect(outcome.spySawFrames)
        #expect(!outcome.spyCaughtToken)
        #expect(outcome.origin == BenchPage.relayOrigin)
    }

    @Test func relayRefusesAFirstFrameThatIsNotInitialize() {
        #expect(NativeRelayTransport.addToken("t", to: #"{"method":"session/new"}"#) == nil)
        let added = NativeRelayTransport.addToken("t", to: #"{"method":"initialize","params":{"_meta":{"acpmux":{"x":1}}}}"#) ?? ""
        #expect(added.contains("\"localAppToken\":\"t\"") && added.contains("\"x\":1"))
    }
}
