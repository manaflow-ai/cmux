import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for transport-independent remote-tmux seed cutover.
///
/// Tailscale SSH changes read latency and chunk boundaries, but preserves byte
/// order. These tests therefore feed the real control parser in deliberately
/// uneven chunks and assert at the connection observer boundary: output already
/// represented by `capture-pane` must not escape ahead of the seed, while output
/// after the capture block must be replayed exactly once before pane state.
@MainActor
@Suite struct RemoteTmuxPaneSeedTransportTests {
    @Test func laggingControlOutputCursorCannotReplayCapturedReconnectOutput() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 7 else { return }
            rendered.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)
        let commands = String(decoding: fixture.pipe.fileHandleForReading.availableData, as: UTF8.self)

        // Model tmux's pane grid and this control client's output cursor as
        // separate authorities. On reconnect the grid may already contain a
        // record while the client's cursor still owes its `%output`. Without a
        // server-side cursor reset, transport latency can deliver that stale
        // notification after capture even though capture already painted it.
        let resetOutputCursor = commands.contains(
            "refresh-client -A %7:off -A %7:on"
        )
        let marker = "AUTORECONNECT_STREAM_29"
        var stream = Data()
        var commandNumber = 20
        for kind in fixture.connection.pendingCommandKindsForTesting {
            let lines: [String]
            switch kind {
            case .paneAltScreen:
                lines = ["0"]
            case .capturePane:
                lines = ["before", marker, "after"]
            case .paneState:
                lines = [Self.paneStateLine(cursorX: 5, cursorY: 2)]
            default:
                lines = []
            }
            stream.append(Self.commandResultBlock(number: commandNumber, lines: lines))
            commandNumber += 1
            if case .capturePane = kind, !resetOutputCursor {
                stream.append(Data("%output %7 \\015\\012\(marker)\r\n".utf8))
            }
        }
        deliverRechunked(stream, to: fixture.connection)

        #expect(Self.occurrences(of: marker, in: rendered) == 1)
    }

    @Test func reconnectReadyWaitsForEveryPaneSeedToFinish() {
        let fixture = attachedConnection()
        defer { fixture.close() }

        fixture.connection.pendingAttachRedrawKick = false
        fixture.connection.windowsByID = [
            1: RemoteTmuxWindow(
                id: 1,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(7)
                )
            ),
            2: RemoteTmuxWindow(
                id: 2,
                width: 80,
                height: 24,
                layout: RemoteTmuxLayoutNode(
                    width: 80, height: 24, x: 0, y: 0, content: .pane(8)
                )
            ),
        ]

        var reconnectReadyCount = 0
        let token = fixture.connection.addObserver(
            onReconnectReady: { reconnectReadyCount += 1 }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.reseedAfterReconnect()
        #expect(reconnectReadyCount == 0)

        var finishedPaneSeeds = 0
        var commandNumber = 30
        while let kind = fixture.connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            switch kind {
            case .paneReflow:
                lines = ["0|zsh"]
            case .paneAltScreen:
                lines = ["0"]
            case .capturePane:
                lines = ["prompt", "❯"]
            case .paneState:
                lines = [Self.paneStateLine(cursorX: 1, cursorY: 1)]
            case .panePath:
                lines = ["/tmp"]
            default:
                lines = []
            }
            fixture.connection.handleMessageForTesting(
                .commandResult(commandNumber: commandNumber, lines: lines, isError: false)
            )
            commandNumber += 1
            if case .paneState = kind {
                finishedPaneSeeds += 1
                if finishedPaneSeeds < 2 {
                    #expect(reconnectReadyCount == 0)
                }
            }
        }

        #expect(finishedPaneSeeds == 2)
        #expect(reconnectReadyCount == 1)
    }

    @Test func rechunkedLiveEchoCutsOverAtomicallyAtCaptureReply() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var writes: [Data] = []
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 7 else { return }
            writes.append(data)
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 7)

        let paneState = Self.paneStateLine(cursorX: 10, cursorY: 1)
        deliverRechunked(
            Self.seedRaceStream(
                preCaptureOutput: "hostname",
                capturedRows: ["prompt", "❯ hostname"],
                postCaptureOutput: "\\015\\012nuc-14-pro",
                paneState: paneState
            ),
            to: fixture.connection
        )

        var expected = RemoteTmuxControlConnection.altScreenExitSequence
        expected.append(Data("\u{1b}[H\u{1b}[2Jprompt\r\n❯ hostname".utf8))
        expected.append(Data("\r\nnuc-14-pro".utf8))
        expected.append(
            RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )

        #expect(writes == [expected])
    }

    @Test func titleEscapeSplitAcrossSnapshotBoundaryCannotConsumeSeed() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var filter = RemoteTmuxScreenTitleFilter()
        var rendered = Data()
        let token = fixture.connection.addObserver(onPaneOutput: { paneID, data in
            guard paneID == 9 else { return }
            rendered.append(filter.filter(data))
        })
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 9)

        let paneState = Self.paneStateLine(cursorX: 1, cursorY: 0)
        deliverRechunked(
            Self.seedRaceStream(
                // A screen/tmux title escape may itself cross `%output` records.
                // The snapshot is authoritative terminal content, not a
                // continuation of this incomplete live escape.
                preCaptureOutput: "\\033kremote-title",
                capturedRows: ["dir git:main", "❯"],
                postCaptureOutput: "\\033\\134x",
                paneState: paneState,
                paneID: 9
            ),
            to: fixture.connection
        )

        var unfilteredSeed = RemoteTmuxControlConnection.altScreenExitSequence
        unfilteredSeed.append(Data("\u{1b}[H\u{1b}[2Jdir git:main\r\n❯".utf8))
        unfilteredSeed.append(Data("\u{1b}\\x".utf8))
        unfilteredSeed.append(
            RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )
        var cleanBoundaryFilter = RemoteTmuxScreenTitleFilter()
        let expected = cleanBoundaryFilter.filter(unfilteredSeed)

        #expect(rendered == expected)
        #expect(String(decoding: rendered, as: UTF8.self).contains("dir git:main"))
    }

    @Test func seedAwareObserverReceivesTypedCutoverWithoutCompatibilityWrite() throws {
        let fixture = attachedConnection()
        defer { fixture.close() }

        var liveWrites: [Data] = []
        var seeds: [RemoteTmuxPaneSeed] = []
        let token = fixture.connection.addObserver(
            onPaneOutput: { paneID, data in
                guard paneID == 5 else { return }
                liveWrites.append(data)
            },
            onPaneSeed: { paneID, seed in
                guard paneID == 5 else { return }
                seeds.append(seed)
            }
        )
        defer { fixture.connection.removeObserver(token) }

        fixture.connection.capturePane(paneId: 5)
        let paneState = Self.paneStateLine(cursorX: 3, cursorY: 2)
        deliverRechunked(
            Self.seedRaceStream(
                preCaptureOutput: "before-capture",
                capturedRows: ["authoritative"],
                postCaptureOutput: "after-capture",
                paneState: paneState,
                paneID: 5
            ),
            to: fixture.connection
        )

        let seed = try #require(seeds.first)
        #expect(seeds.count == 1)
        #expect(liveWrites.isEmpty)
        #expect(seed.discardedOutput == [Data("before-capture".utf8)])
        #expect(seed.catchUpOutput == [Data("after-capture".utf8)])

        var snapshot = RemoteTmuxControlConnection.altScreenExitSequence
        snapshot.append(Data("\u{1b}[H\u{1b}[2Jauthoritative".utf8))
        #expect(seed.snapshot == snapshot)
        #expect(
            seed.state
                == RemoteTmuxControlMessageDecoding().paneStateSeedSequence(from: paneState)
        )
    }

    private static func seedRaceStream(
        preCaptureOutput: String,
        capturedRows: [String],
        postCaptureOutput: String,
        paneState: String,
        paneID: Int = 7
    ) -> Data {
        let text = "%output %\(paneID) \(preCaptureOutput)\r\n"
            + "%begin 1700000000 11 0\r\n"
            + "0\r\n"
            + "%end 1700000000 11 0\r\n"
            + "%begin 1700000000 12 0\r\n"
            + capturedRows.joined(separator: "\r\n") + "\r\n"
            + "%end 1700000000 12 0\r\n"
            + "%output %\(paneID) \(postCaptureOutput)\r\n"
            + "%begin 1700000000 13 0\r\n"
            + paneState + "\r\n"
            + "%end 1700000000 13 0\r\n"
        return Data(text.utf8)
    }

    private static func paneStateLine(cursorX: Int, cursorY: Int) -> String {
        "cursor_x=\(cursorX),cursor_y=\(cursorY),"
            + "scroll_region_upper=0,scroll_region_lower=23,"
            + "cursor_flag=1,insert_flag=0,keypad_cursor_flag=0,keypad_flag=0,"
            + "wrap_flag=1,origin_flag=0,pane_height=24,"
            + "mouse_all_flag=0,mouse_button_flag=0,mouse_standard_flag=0,"
            + "mouse_sgr_flag=0,mouse_utf8_flag=0"
    }

    private static func commandResultBlock(number: Int, lines: [String]) -> Data {
        let body = lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
        return Data(
            ("%begin 1700000000 \(number) 0\r\n"
                + body
                + "%end 1700000000 \(number) 0\r\n").utf8
        )
    }

    private static func occurrences(of needle: String, in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: needle).count - 1
    }

    /// Simulates a lumpy userspace SSH transport without clocks: tmux protocol
    /// bytes remain ordered, but lines and escape payloads cross read boundaries.
    private func deliverRechunked(_ bytes: Data, to connection: RemoteTmuxControlConnection) {
        var parser = RemoteTmuxControlStreamParser()
        let chunkSizes = [1, 13, 2, 31, 5, 3, 47, 8]
        var offset = bytes.startIndex
        var chunkIndex = 0
        while offset < bytes.endIndex {
            let count = min(
                chunkSizes[chunkIndex % chunkSizes.count],
                bytes.distance(from: offset, to: bytes.endIndex)
            )
            let end = bytes.index(offset, offsetBy: count)
            for message in parser.feed(Data(bytes[offset..<end])) {
                connection.handleMessageForTesting(message)
            }
            offset = end
            chunkIndex += 1
        }
    }

    private func attachedConnection() -> Fixture {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "seed-transport.test"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-pane-seed-transport-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 1, lines: [], isError: false)
        )
        _ = pipe.fileHandleForReading.availableData
        return Fixture(connection: connection, writer: writer, pipe: pipe)
    }

    private struct Fixture {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe

        @MainActor func close() {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
    }
}
