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
        #expect(cache.load() == nil)
        let config = RemoteConfig(flags: ["hostsTab": .bool(true)], demoContent: true)
        cache.save(config)
        #expect(cache.load() == config)
        cache.clear()
        #expect(cache.load() == nil)
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
}
