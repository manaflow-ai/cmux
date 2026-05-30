import Foundation
import Testing
@testable import cmux

@Suite struct HostAllowlistTests {
    @Test func loopbackHostAllowedWithoutOrigin() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:9778", origin: nil) == .ok)
        #expect(a.evaluate(host: "localhost:9778", origin: nil) == .ok)
    }

    @Test func loopbackHostCaseInsensitive() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "LocalHost:9778", origin: nil) == .ok)
    }

    @Test func spoofedHostForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "evil.example:9778", origin: nil) == .forbiddenHost)
    }

    @Test func wrongPortForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:1234", origin: nil) == .forbiddenHost)
    }

    @Test func bareHostnameWithoutPortRejected() {
        // The Host header includes the port for non-default ports;
        // a bare hostname is not in the allow-list.
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1", origin: nil) == .forbiddenHost)
    }

    @Test func missingHostReportedAsMissingHost() {
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: nil, origin: nil) == .missingHost)
    }

    @Test func nonLoopbackOriginForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(
            a.evaluate(
                host: "127.0.0.1:9778",
                origin: "https://evil.example"
            ) == .forbiddenOrigin
        )
    }

    @Test func loopbackOriginAllowed() {
        let a = HostAllowlist(port: 9778)
        #expect(
            a.evaluate(
                host: "127.0.0.1:9778",
                origin: "http://127.0.0.1:9778"
            ) == .ok
        )
        #expect(
            a.evaluate(
                host: "localhost:9778",
                origin: "http://localhost:9778"
            ) == .ok
        )
    }

    @Test func missingOriginAllowedForCLICallers() {
        // CLI / curl callers don't send Origin; this is treated as a
        // negative signal only, not a positive one.
        let a = HostAllowlist(port: 9778)
        #expect(a.evaluate(host: "127.0.0.1:9778", origin: nil) == .ok)
    }

    @Test func wrongPortOriginForbidden() {
        let a = HostAllowlist(port: 9778)
        #expect(
            a.evaluate(
                host: "127.0.0.1:9778",
                origin: "http://127.0.0.1:1234"
            ) == .forbiddenOrigin
        )
    }

    @Test func httpsOriginOnLoopbackPortRejected() {
        // Listener is HTTP-only; HTTPS origin on the same port is
        // not a same-origin context the listener serves.
        let a = HostAllowlist(port: 9778)
        #expect(
            a.evaluate(
                host: "127.0.0.1:9778",
                origin: "https://127.0.0.1:9778"
            ) == .forbiddenOrigin
        )
    }
}
