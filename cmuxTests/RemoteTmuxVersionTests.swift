import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the `tmux -V` parser + the minimum-version gate for `cmux ssh-tmux`.
/// The version boundary was established empirically (Docker matrix): tmux < 3.2
/// lacks `refresh-client -B` subscriptions (and 1.x lacks `%begin`/`%end`
/// framing), so the mirror needs tmux >= 3.2. The exact `tmux -V` strings used
/// here were captured from real containers (1.8 / 2.1 / 2.6 / 3.1c / 3.2a / 3.3a).
@Suite struct RemoteTmuxVersionTests {
    typealias V = RemoteTmuxVersion

    @Test func parsesRealVersionStrings() {
        #expect(V.parse("tmux 1.8") == V(major: 1, minor: 8, letterRank: 0))
        #expect(V.parse("tmux 2.1") == V(major: 2, minor: 1, letterRank: 0))
        #expect(V.parse("tmux 3.1c") == V(major: 3, minor: 1, letterRank: 3))
        #expect(V.parse("tmux 3.2a") == V(major: 3, minor: 2, letterRank: 1))
        #expect(V.parse("tmux 3.3a") == V(major: 3, minor: 3, letterRank: 1))
        #expect(V.parse("tmux 3.6a\n") == V(major: 3, minor: 6, letterRank: 1))
    }

    @Test func gateRejectsBelow32AndAcceptsFrom32() throws {
        // Below the minimum — these should be rejected.
        for s in ["tmux 1.8", "tmux 2.1", "tmux 2.6", "tmux 3.0", "tmux 3.1", "tmux 3.1c"] {
            let v = try #require(V.parse(s), "\(s)")
            #expect(!v.meetsMinimum, "\(s) should be unsupported")
        }
        // At/above the minimum — accepted.
        for s in ["tmux 3.2", "tmux 3.2a", "tmux 3.3a", "tmux 3.4", "tmux 3.6a", "tmux 4.0"] {
            let v = try #require(V.parse(s), "\(s)")
            #expect(v.meetsMinimum, "\(s) should be supported")
        }
    }

    @Test func letterRankSortsAfterBaseButDoesNotCrossMinor() {
        #expect(V.parse("tmux 3.2")! < V.parse("tmux 3.2a")!)   // 3.2 < 3.2a
        #expect(V.parse("tmux 3.2a")! < V.parse("tmux 3.3")!)   // 3.2a < 3.3
        #expect(V.parse("tmux 3.1c")! < V.parse("tmux 3.2")!)   // 3.1c < 3.2 (so 3.1c is rejected)
    }

    @Test func unparseableVersionsReturnNil() {
        // Dev / distro builds with no major.minor — caller treats as "unknown, allow".
        #expect(V.parse("tmux master") == nil)
        #expect(V.parse("tmux next-3.4") != nil) // "3.4" IS present → parsed
        #expect(V.parse("tmux") == nil)
        #expect(V.parse("") == nil)
        #expect(V.parse("garbage 3.4") == nil)
    }

    @Test func parserIgnoresVersionLikeShellBanners() {
        #expect(V.parse("Welcome to Ubuntu 20.04.6 LTS\ntmux 1.8") == V(major: 1, minor: 8, letterRank: 0))
        #expect(V.parse("tmux helper 20.04\ntmux 2.6") == V(major: 2, minor: 6, letterRank: 0))
        #expect(V.parse("tmux 2.6\ntmux helper 20.04") == V(major: 2, minor: 6, letterRank: 0))
        #expect(V.parse("OpenSSH_9.6p1 LibreSSL 3.3.6") == nil)
    }

    @Test func parsesServerReportedVersionFormat() {
        #expect(V.parseServerFormat("3.1c\n") == V(major: 3, minor: 1, letterRank: 3))
        #expect(V.parseServerFormat("Welcome to Ubuntu 20.04.6 LTS\n3.2a\n") == V(major: 3, minor: 2, letterRank: 1))
        #expect(V.parseServerFormat("3.2a\nhelper 20.04\n") == V(major: 3, minor: 2, letterRank: 1))
        #expect(V.parseServerFormat("3.1c\n20.04.6\n") == V(major: 3, minor: 1, letterRank: 3))
        #expect(V.parseServerFormat("3.2a helper\n") == nil)
        #expect(V.parseServerFormat("Welcome to Ubuntu 20.04.6 LTS\n") == nil)
        #expect(V.parseServerFormat("20.04.6\n") == nil)
        #expect(V.parse("3.2a\n") == nil)
    }

    @Test func displayStringRoundTrips() {
        #expect(V.parse("tmux 3.2a")!.displayString == "3.2a")
        #expect(V.parse("tmux 1.8")!.displayString == "1.8")
        #expect(V.parse("tmux 3.1c")!.displayString == "3.1c")
        #expect(V.minimumSupported.displayString == "3.2")
    }

    @Test func unsupportedErrorMessageInterpolatesVersionAndMinimum() {
        let msg = RemoteTmuxError.unsupportedTmux(detected: "2.6").message
        #expect(msg.contains("2.6"))
        #expect(msg.contains("3.2"))
    }
}
