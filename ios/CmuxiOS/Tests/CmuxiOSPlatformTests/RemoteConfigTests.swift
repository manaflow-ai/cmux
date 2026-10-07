import CmuxiOSPlatform
import Foundation
import Testing

@Suite("Remote flags and config")
struct RemoteConfigTests {
    @Test func precedenceIsEnvironmentThenOverrideThenRemoteThenDefault() {
        let all = FlagResolution(environment: false, deviceOverride: true, remote: .bool(true), buildDefault: true)
        #expect(all.value == false && all.layer == .environment)
        let noEnv = FlagResolution(environment: nil, deviceOverride: false, remote: .bool(true), buildDefault: true)
        #expect(noEnv.value == false && noEnv.layer == .deviceOverride)
        let remote = FlagResolution(environment: nil, deviceOverride: nil, remote: .bool(true), buildDefault: false)
        #expect(remote.value == true && remote.layer == .remote)
        let fallback = FlagResolution(environment: nil, deviceOverride: nil, remote: nil, buildDefault: true)
        #expect(fallback.value == true && fallback.layer == .buildDefault)
    }

    @Test func nonBoolRemoteValueIsIgnored() {
        let mismatch = FlagResolution(environment: nil, deviceOverride: nil, remote: .string("yes"), buildDefault: false)
        #expect(mismatch.value == false && mismatch.layer == .buildDefault)
        let number = FlagResolution(environment: nil, deviceOverride: nil, remote: .int(1), buildDefault: false)
        #expect(number.layer == .buildDefault)
    }

    @Test func decodesTheWireShapeAndToleratesMissingFields() throws {
        let json = #"{"flags":{"feedTab":true,"maxPanes":4,"variant":"b"},"minimumMacProtocol":2,"extra":"ignored"}"#
        let config = try JSONDecoder().decode(RemoteConfig.self, from: Data(json.utf8))
        #expect(config.revision == 0)
        #expect(config.flags == ["feedTab": .bool(true), "maxPanes": .int(4), "variant": .string("b")])
        #expect(config.minimumMacProtocol == 2)
        #expect(config.whatsNewRevision == nil)
        #expect(config.demoContent == false)
        let empty = try JSONDecoder().decode(RemoteConfig.self, from: Data("{}".utf8))
        #expect(empty == .empty)
    }

    @Test func cacheRoundTripsAndClears() throws {
        let defaults = try #require(UserDefaults(suiteName: "c16.remote." + UUID().uuidString))
        let cache = RemoteConfigCache(defaults: defaults)
        #expect(cache.load(for: "user-a") == nil)
        let config = RemoteConfig(flags: ["hostsTab": .bool(true)], demoContent: true)
        cache.save(config, for: "user-a")
        #expect(cache.load(for: "user-a") == config)
        #expect(cache.load(for: "user-b") == nil)
        cache.clear(for: "user-a")
        #expect(cache.load(for: "user-a") == nil)
    }

    @Test func mockSourceStreamsCurrentThenChanges() async {
        let source = MockRemoteConfigSource()
        var iterator = await source.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.value == .empty)
        await source.set(RemoteConfig(flags: ["feedTab": .bool(true)]))
        let second = await iterator.next()
        #expect(second?.value.flags["feedTab"] == .bool(true))
        #expect((second?.revision ?? 0) > (first?.revision ?? 0))
    }

    @Test func httpSourceMapsTheAuthenticatedEnvelopeAndKeepsCachedProjection() async throws {
        let body = Data(#"{"ok":true,"value":{"version":7,"flags":{"feedTab":true,"variant":"canary"},"minimumMacProtocol":2,"demoContent":true}}"#.utf8)
        let source = URLSessionRemoteConfigSource(
            baseURL: URL(string: "https://api.example.test")!,
            appVersion: "2.4.0",
            initial: RemoteConfig(revision: 3, flags: ["old": .bool(true)]),
            token: { "session-token" },
            refreshInterval: .seconds(3600),
            fetch: { request in
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
                #expect(request.value(forHTTPHeaderField: "x-cmux-client-version") == "2.4.0")
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        var iterator = await source.updates().makeAsyncIterator()
        let connecting = await iterator.next()
        #expect(connecting?.connection == .connecting)
        let fetched = await iterator.next()
        #expect(fetched?.connection == .live(path: "https"))
        #expect(fetched?.value == RemoteConfig(revision: 7,
                                                flags: ["feedTab": .bool(true), "variant": .string("canary")],
                                                minimumMacProtocol: 2,
                                                demoContent: true))
    }

    @Test func httpSourceFailsClosedAndDoesNotEraseCachedProjection() async throws {
        let cached = RemoteConfig(revision: 4, flags: ["feedTab": .bool(true)])
        let source = URLSessionRemoteConfigSource(
            baseURL: URL(string: "https://api.example.test")!,
            initial: cached,
            token: { "session-token" },
            refreshInterval: .seconds(3600),
            fetch: { request in
                (Data(#"{"ok":false,"value":{}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
        )
        var iterator = await source.updates().makeAsyncIterator()
        let connecting = await iterator.next()
        #expect(connecting?.value == cached)
        let failed = await iterator.next()
        #expect(failed?.connection == .offline(reason: "remote config unavailable"))
        #expect(failed?.value == cached)
    }

    @Test func httpSourceClampsMalformedNegativeRevisions() async throws {
        let source = URLSessionRemoteConfigSource(
            baseURL: URL(string: "https://api.example.test")!,
            initial: RemoteConfig(revision: -4),
            token: { "session-token" },
            refreshInterval: .seconds(3600),
            fetch: { request in
                let body = Data(#"{"ok":true,"value":{"version":-9,"flags":{}}}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        var iterator = await source.updates().makeAsyncIterator()
        let connecting = await iterator.next()
        #expect(connecting?.revision == 1)
        let fetched = await iterator.next()
        #expect(fetched?.value.revision == 0)
        #expect(fetched?.revision == 2)
    }
}
