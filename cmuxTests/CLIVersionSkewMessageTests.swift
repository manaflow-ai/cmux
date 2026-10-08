import Foundation
import Testing

/// Branch coverage for the CLI's version-skew message. The CLI product tests
/// drive the same code end to end through a fake socket; these cover the
/// branches a subprocess cannot reach cheaply.
///
/// Messages render from a bundle with no string table, so they come out in
/// the English source text whatever the host's language is.
struct CLIVersionSkewMessageTests {
    /// A directory bundle without `Localizable` strings: every
    /// `String(localized:defaultValue:bundle:)` lookup returns its default.
    private static let sourceTextBundle: Bundle = {
        // One fixed directory, emptied first so nothing left in it (by an
        // earlier run or anything else) can supply a string table, and
        // nothing accumulates across runs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-skew-source-text", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Cannot create \(directory.path): \(error)")
        }
        guard let bundle = Bundle(url: directory) else {
            preconditionFailure("Cannot open \(directory.path) as a bundle")
        }
        return bundle
    }()

    private func message(
        cliShortVersion: String? = "0.65.0",
        cliBuild: String? = "108",
        peer: CLIVersionSkew.Peer?
    ) -> String? {
        CLIVersionSkew.message(
            method: "workspace.create",
            socketPath: "/tmp/cmux.sock",
            cliVersion: "cmux 0.65.0 (108)",
            cliShortVersion: cliShortVersion,
            cliBuild: cliBuild,
            cliPath: "/usr/local/bin/cmux",
            peer: peer,
            original: "method_not_found: Unknown method",
            bundle: Self.sourceTextBundle
        )
    }

    @Test("An app that lists the method keeps the original error")
    func listedMethodIsNotSkew() {
        let peer = CLIVersionSkew.Peer(
            app: "cmux-next", version: "0.3.0", build: "1", cliPath: nil,
            methods: ["workspace.create"]
        )
        #expect(message(peer: peer) == nil)
    }

    @Test("A newer app points at its own CLI")
    func newerAppSaysCLIOlder() throws {
        let peer = CLIVersionSkew.Peer(
            app: "cmux", version: "0.66.0", build: "120",
            cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux"
        )
        let text = try #require(message(peer: peer))
        #expect(text.contains("This CLI is older than the app"))
        #expect(text.contains("/Applications/cmux.app/Contents/Resources/bin/cmux"))
        #expect(text.contains("cmux 0.66.0 (120)"))
    }

    @Test("An older app gets the relaunch fix")
    func olderAppSaysRelaunch() throws {
        let peer = CLIVersionSkew.Peer(app: "cmux", version: "0.64.2", build: "100", cliPath: nil)
        #expect(try #require(message(peer: peer)).contains("Quit and reopen cmux"))
    }

    @Test("An unparsable app version does not guess a direction")
    func unparsablePeerVersionIsUnknown() throws {
        let peer = CLIVersionSkew.Peer(app: "cmux", version: "dev", build: nil, cliPath: nil)
        let text = try #require(message(peer: peer))
        #expect(text.contains("Could not read the app's version"))
        #expect(!text.contains("is older than"))
    }

    @Test("A CLI without its own version keeps the original error")
    func unknownCLIVersionIsNotSkew() {
        let peer = CLIVersionSkew.Peer(app: "cmux", version: "0.64.0", build: nil, cliPath: nil)
        #expect(message(cliShortVersion: nil, peer: peer) == nil)
        #expect(message(cliShortVersion: "dev", peer: peer) == nil)
    }

    @Test("Builds break a short-version tie only when both are known")
    func buildOrdering() {
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "108", peerVersion: "0.65.0", peerBuild: "109") == .orderedAscending)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "110", peerVersion: "0.65.0", peerBuild: "109") == .orderedDescending)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "108", peerVersion: "0.65.0", peerBuild: nil) == .orderedSame)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: nil, peerVersion: "0.65.0", peerBuild: "109") == .orderedSame)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "abc", peerVersion: "0.65.0", peerBuild: "abd") == .orderedSame)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.64.0", cliBuild: "200", peerVersion: "0.65.0", peerBuild: "100") == .orderedAscending)
        // A suffixed build is not a number; it must not decide the order.
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "108-dev", peerVersion: "0.65.0", peerBuild: "109") == .orderedSame)
        #expect(CLIVersionSkew.versionOrder(cliShortVersion: "0.65.0", cliBuild: "108", peerVersion: "0.65.0", peerBuild: "109 beta") == .orderedSame)
    }

    @Test("Same version and build keeps the original error")
    func sameBuildIsNotSkew() {
        let peer = CLIVersionSkew.Peer(app: "cmux", version: "0.65.0", build: "108", cliPath: nil)
        #expect(message(peer: peer) == nil)
    }

    @Test("Dotted versions compare numerically and ignore suffixes")
    func compareEdgeCases() {
        #expect(CLIVersionSkew.compare("0.64.25", "0.65.0") == .orderedAscending)
        #expect(CLIVersionSkew.compare("0.65", "0.65.0") == .orderedSame)
        #expect(CLIVersionSkew.compare("0.65.0-rc.1", "0.65.0") == .orderedSame)
        #expect(CLIVersionSkew.compare("0.65.0 (123)", "0.65.0") == .orderedSame)
        #expect(CLIVersionSkew.compare("0.10.0", "0.9.0") == .orderedDescending)
        #expect(CLIVersionSkew.compare(nil, "0.65.0") == nil)
        #expect(CLIVersionSkew.compare("dev", "0.65.0") == nil)
    }

    @Test("Peer text loses control characters and bidi overrides")
    func printableStripsControls() {
        #expect(CLITerminalText.printable("a\u{1B}[31mb\u{07}c\u{9B}d\ne\r\u{202E}f\u{2066}g") == "a[31mbcdefg")
        #expect(CLITerminalText.printable("cmux-next 0.3.0 日本") == "cmux-next 0.3.0 日本")
        #expect(CLITerminalText.printable("/a\u{200F}b\u{200E}c\u{061C}d\u{2028}e\u{2029}f") == "/abcdef")
        #expect(CLITerminalText.printable("one\r\ntwo\tthree\u{2028}\u{1B}[0m", keepingLineBreaks: true) == "one\ntwo\tthree[0m")
        let peer = CLIVersionSkew.Peer(identify: ["app": " \u{1B}]0;x\u{07} ", "version": "\n\t"])
        #expect(peer.app == "]0;x")
        #expect(peer.version == nil)
    }

    @Test("A multi-line original error stays on its one line")
    func multiLineOriginalIsJoined() throws {
        let text = try #require(CLIVersionSkew.message(
            method: "workspace.create",
            socketPath: "/tmp/cmux.sock",
            cliVersion: "cmux 0.65.0 (108)",
            cliShortVersion: "0.65.0",
            cliPath: nil,
            peer: CLIVersionSkew.Peer(app: "cmux", version: "0.64.0", build: nil, cliPath: nil),
            original: "method_not_found: x\n\nReason:\n  y",
            bundle: Self.sourceTextBundle
        ))
        #expect(text.hasSuffix("(method_not_found: x  Reason:   y)"))
    }

    @Test("The echoed original error is printable too")
    func originalErrorIsSanitized() throws {
        let text = try #require(CLIVersionSkew.message(
            method: "workspace.create",
            socketPath: "/tmp/cmux.sock",
            cliVersion: "cmux 0.65.0 (108)",
            cliShortVersion: "0.65.0",
            cliPath: nil,
            peer: CLIVersionSkew.Peer(app: "cmux", version: "0.64.0", build: nil, cliPath: nil),
            original: "method_not_found: x\u{1B}[2J",
            bundle: Self.sourceTextBundle
        ))
        #expect(!text.unicodeScalars.contains { $0 == "\u{1B}" })
        #expect(text.hasSuffix("(method_not_found: x[2J)"))
    }
}
