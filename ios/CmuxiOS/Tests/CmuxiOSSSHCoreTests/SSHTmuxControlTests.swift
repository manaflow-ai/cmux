import CmuxMobileSSH
@testable import CmuxiOSSSHCore
import Foundation
import Testing

@Suite struct SSHTmuxControlTests {
    @Test func decoderPreservesBinaryAndFragmentedEscapes() throws {
        var decoder = SSHTmuxControlDecoder()
        let wire = Data("%output %2 a\\033[H\\377\\134\n".utf8)
        var frames: [SSHTmuxControlDecoder.Event] = []
        for byte in wire { frames += try decoder.append(Data([byte])) }
        #expect(frames == [.notification(Data("%output %2 a\\033[H\\377\\134".utf8))])
        #expect(try SSHTmuxControlDecoder.unescape(Data("a\\033[H\\377\\134".utf8)) == Data([97, 27, 91, 72, 255, 92]))
        #expect(try SSHTmuxControlDecoder.unescape(Data([92, 92, 48, 51, 51]), capture: true) == Data([92, 48, 51, 51]))
        #expect(throws: SSHSessionFailure.shellRejected) { try SSHTmuxControlDecoder.unescape(Data("\\999".utf8)) }
        #expect(throws: SSHSessionFailure.shellRejected) { try SSHTmuxControlDecoder.unescape(Data("\\12".utf8)) }
    }

    @Test func capturedProtocolLookingTextIsNotAnEvent() throws {
        var decoder = SSHTmuxControlDecoder()
        let frames = try decoder.append(Data("%begin 100 7 1\n%output %2 text\n%end 100 8 1\n%end 100 7 1\n".utf8))
        #expect(frames == [.response(lines: [Data("%output %2 text".utf8), Data("%end 100 8 1".utf8)], failed: false)])
        #expect(try decoder.append(Data("%begin 100 8 1\nmissing\n%error 100 8 1\n".utf8))
            == [.response(lines: [Data("missing".utf8)], failed: true)])
    }

    @Test func oversizedOrUnframedProtocolFailsClosed() throws {
        var decoder = SSHTmuxControlDecoder()
        #expect(throws: SSHSessionFailure.shellRejected) {
            try decoder.append(Data(repeating: 65, count: SSHTmuxControlDecoder.maximumLine + 1))
        }
        var fresh = SSHTmuxControlDecoder()
        #expect(throws: SSHSessionFailure.shellRejected) { try fresh.append(Data("echoed shell command\n".utf8)) }
        #expect(SSHTmuxWindow(sessionID: "$1;kill-server", windowID: "@2", serverPID: 42, serverStart: 100) == nil)
        #expect(SSHTmuxWindow(sessionID: "$1", windowID: "@2\n", serverPID: 42, serverStart: 100) == nil)
        #expect(SSHTmuxWindow(sessionID: "1", windowID: "@2", serverPID: 42, serverStart: 100) == nil)
    }

    @Test func modernDiscoveryUsesStableIDsAndNeverDowngradesMalformedWindows() throws {
        let discovery = SSHSessionDiscovery()
        let listing = "@tmux2\t/usr/bin/tmux\nS\twork\t1\t0\t1\nW2\twork\t0\t1\t$1\t@9\t42\t100\tshell\n"
        let window = try #require(discovery.parse(listing).first?.windows.first?.target)
        #expect(window.surfaceID == "ssh:tmux:42-100:$1:@9")
        #expect(window.attachCommand == "exec '/usr/bin/tmux' -C -N attach-session -E -f ignore-size,no-output -t '$1'")
        let renamed = listing.replacingOccurrences(of: "work", with: "renamed").replacingOccurrences(of: "W2\trenamed\t0", with: "W2\trenamed\t4")
        #expect(discovery.parse(renamed).first?.windows.first?.target.surfaceID == window.surfaceID)
        #expect(discovery.parse(renamed).first?.id == discovery.parse(listing).first?.id)
        #expect(discovery.parse(listing.replacingOccurrences(of: "@9", with: "@9;kill-server")).isEmpty)
        #expect(discovery.parse(listing.replacingOccurrences(of: "/usr/bin/tmux", with: "/bad/../tmux")).isEmpty)
    }

    @Test func hydrationThenLiveOutputAndHexInputStayOnTheDiscoveredPane() async throws {
        let base = TmuxTestChannel()
        let window = try #require(SSHTmuxWindow(sessionID: "$1", windowID: "@9", serverPID: 42, serverStart: 100))
        let control = SSHTmuxControlChannel(base: base, window: window, cols: 80, rows: 24, changed: {})
        let starting = Task { try await control.start() }
        defer { starting.cancel() }
        var writes = base.writes.makeAsyncIterator()
        await base.reply([]) // Initial attach command's response.
        #expect(await writes.next() == "display-message -p '#{pid} #{start_time}'\n")
        await base.reply(["42 100"])
        let discovery = try #require(await writes.next())
        #expect(discovery.contains("refresh-client -f '!ignore-size' -C '@9:80x24'"))
        #expect(discovery.contains("list-panes -s -t '$1'"))
        #expect(!discovery.contains("select-window"))
        await base.reply([])
        await base.reply([])
        await base.reply(["@9 %2 80 24", "@10 %3 80 24"])
        let hydration = try #require(await writes.next())
        #expect(hydration.contains("capture-pane -p -e -C -t '%2'"))
        #expect(hydration.contains("-A '%3:off'"))
        await base.reply(["ready"])
        await base.reply(["%2 80 24 0 0 0 0 23 1 0 0 0 1 0 1 0 0 0 0 0"])
        await base.reply([])
        try await starting.value
        var output = control.events.makeAsyncIterator()
        guard case .stdout(let snapshot)? = await output.next() else { Issue.record("no snapshot"); return }
        #expect(snapshot.starts(with: Data("\u{1b}c\u{1b}[Hready".utf8)))
        await base.notify("%output %3 invisible\n%output %2 a\\033[H\n")
        #expect(await output.next() == .stdout(Data("a\u{1b}[H".utf8)))
        try await control.write(Data(";kill-server\n".utf8))
        let input = try #require(await writes.next())
        #expect(input == "send-keys -H -t '%2' 3b 6b 69 6c 6c 2d 73 65 72 76 65 72 0a\n")
        await control.close()
        #expect(await base.closed)
    }

    @Test func multiPaneWindowIsRefusedWithoutAttachingAnUnrelatedPane() async throws {
        let base = TmuxTestChannel()
        let window = try #require(SSHTmuxWindow(sessionID: "$1", windowID: "@9", serverPID: 42, serverStart: 100))
        let control = SSHTmuxControlChannel(base: base, window: window, cols: 80, rows: 24, changed: {})
        let starting = Task { try await control.start() }
        var writes = base.writes.makeAsyncIterator()
        await base.reply([])
        _ = await writes.next()
        await base.reply(["42 100"])
        _ = await writes.next()
        await base.reply([])
        await base.reply([])
        await base.reply(["@9 %2 40 24", "@9 %3 40 24"])
        await #expect(throws: SSHSessionFailure.shellRejected) { try await starting.value }
        await control.close()
        #expect(await base.closed)
    }

    @Test func replacedServerIsRejectedBeforeAnyResizeOrInput() async throws {
        let base = TmuxTestChannel()
        let window = try #require(SSHTmuxWindow(sessionID: "$1", windowID: "@9", serverPID: 42, serverStart: 100))
        let control = SSHTmuxControlChannel(base: base, window: window, cols: 80, rows: 24, changed: {})
        let starting = Task { try await control.start() }
        var writes = base.writes.makeAsyncIterator()
        await base.reply([])
        #expect(await writes.next() == "display-message -p '#{pid} #{start_time}'\n")
        await base.reply(["42 101"])
        await #expect(throws: SSHSessionFailure.sessionGone) { try await starting.value }
        await control.close()
        #expect(await writes.next() == nil)
        #expect(await base.closed)
    }

    @Test func cancellationReleasesAControlChannelWaitingForItsFirstReply() async throws {
        let base = TmuxTestChannel()
        let window = try #require(SSHTmuxWindow(sessionID: "$1", windowID: "@9", serverPID: 42, serverStart: 100))
        let control = SSHTmuxControlChannel(base: base, window: window, cols: 80, rows: 24, changed: {})
        let starting = Task { try await control.start() }
        starting.cancel()
        await #expect(throws: (any Error).self) { try await starting.value }
        await control.close()
        #expect(await base.closed)
    }

    @Test func snapshotRefusesAStaleGridAndRestoresApplicationInputModes() throws {
        let metadata = [Data("%2 80 24 3 2 1 0 23 1 1 1 0 1 0 1 0 0 0 0 0".utf8)]
        let replay = try SSHTmuxSnapshot.replay(lines: [Data("hello".utf8)], metadata: metadata, pane: "%2", cols: 80, rows: 24)
        let text = String(decoding: replay, as: UTF8.self)
        #expect(text.contains("\u{1b}[?1049h"))
        #expect(text.contains("\u{1b}[?1h"))
        #expect(text.contains("\u{1b}[?2004h"))
        #expect(text.hasSuffix("\u{1b}[3;4H"))
        #expect(throws: SSHSessionFailure.shellRejected) {
            try SSHTmuxSnapshot.replay(lines: [], metadata: metadata, pane: "%2", cols: 40, rows: 24)
        }
    }
}
