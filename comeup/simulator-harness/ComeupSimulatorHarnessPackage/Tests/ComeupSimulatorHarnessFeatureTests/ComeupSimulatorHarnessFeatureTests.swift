import Foundation
import Testing
import UIKit
@testable import ComeupSimulatorHarnessFeature

@Test
func mobileHomeFixtureContainsAuthDiscoveryAndTerminalTree() throws {
    let snapshot = CmuxMobileHomeSnapshot.fixture
    #expect(snapshot.auth.state == .signedIn)
    #expect(snapshot.nodes.contains { $0.status == .online && $0.route.hasPrefix("iroh://") })
    #expect(snapshot.nodes.contains { $0.route.hasPrefix("rivet://") })

    let workspace = try #require(snapshot.workspace(id: "workspace-ios-port"))
    #expect(workspace.title == "iOS port")
    #expect(workspace.terminalTree.map(\.terminal.id).contains("terminal-daemon"))
    #expect(workspace.terminal(id: "terminal-shell")?.size == CmuxTerminalSize(cols: 66, rows: 18))
}

@MainActor
@Test
func fullGhosttySurfaceRendersOutputAndProducesInput() throws {
    let workspace = try #require(CmuxMobileHomeSnapshot.fixture.workspace(id: "workspace-ios-port"))
    let terminal = try #require(workspace.terminal(id: "terminal-shell"))
    let delegate = GhosttySurfaceTestDelegate()
    let surfaceView = GhosttyTerminalSurfaceView(
        runtime: try GhosttyRuntime.shared(),
        delegate: delegate
    )
    surfaceView.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
    surfaceView.layoutIfNeeded()

    surfaceView.processOutput(Data((terminal.rows.joined(separator: "\r\n") + "\r\n").utf8))
    let rendered = try #require(surfaceView.renderedTextForTesting())
    #expect(rendered.contains("CMX_SENTINEL_TO_SIM"))
    #expect(rendered.contains("SIM_SENTINEL_FROM_IOS"))

    surfaceView.simulateTextInputForTesting("hello from ios\n")
    #expect(delegate.inputs.contains(Data("hello from ios\r".utf8)))
}

@Test
func simulatorTextHarnessSyncsWithComeupDaemon() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let portText = environment["COMEUP_TEXT_PORT"] ?? environment["TEST_RUNNER_COMEUP_TEXT_PORT"] else {
        return
    }
    let port = try #require(Int(portText))
    let client = try TextHarnessSocket(host: "127.0.0.1", port: port)
    defer { client.close() }

    try client.sendLine("HELLO 90 30")
    let welcome = try client.readLine(containing: "WELCOME client=")
    #expect(welcome.contains("terminal=1"))
    #expect(welcome.contains("size=90x30"))

    try client.sendLine("VISIBLE 1 66 18")
    #expect(try client.readLine(containing: "SIZE terminal=1 66x18") == "SIZE terminal=1 66x18")

    try client.sendLine("WORKSPACE Sim Build")
    #expect(try client.readLine(containing: "WORKSPACE id=2 title=Sim Build") == "WORKSPACE id=2 title=Sim Build")
    let sizedTerminal = try parseSizedTerminal(try client.readLine(containing: "SIZE terminal="), expectedSize: "66x18")
    let focusedTerminal = try parseFocusedTerminal(try client.readLine(containing: "FOCUS terminal="))
    #expect(focusedTerminal == sizedTerminal)

    try client.sendLine("SEND \(focusedTerminal) SWIFT_SOCKET_SENTINEL_FROM_TEST")
    #expect(try client.readLine(containing: "SWIFT_SOCKET_SENTINEL_FROM_TEST").contains("OUTPUT terminal=\(focusedTerminal)"))

    try client.sendLine("PING 77")
    #expect(try client.readLine(containing: "PONG id=77") == "PONG id=77")
}

@MainActor
private final class GhosttySurfaceTestDelegate: GhosttyTerminalSurfaceViewDelegate {
    var inputs: [Data] = []
    var sizes: [TerminalGridSize] = []

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didProduceInput data: Data) {
        inputs.append(data)
    }

    func ghosttyTerminalSurfaceView(_ surfaceView: GhosttyTerminalSurfaceView, didResize size: TerminalGridSize) {
        sizes.append(size)
    }
}

private func parseFocusedTerminal(_ line: String) throws -> Int {
    guard let value = line.split(separator: "=").last, let terminal = Int(value) else {
        throw TextHarnessSocket.Error.malformedLine(line)
    }
    return terminal
}

private func parseSizedTerminal(_ line: String, expectedSize: String) throws -> Int {
    let pieces = line.split(separator: " ")
    guard pieces.count == 3, pieces[0] == "SIZE", pieces[1].hasPrefix("terminal="), pieces[2] == expectedSize else {
        throw TextHarnessSocket.Error.malformedLine(line)
    }
    let value = pieces[1].dropFirst("terminal=".count)
    guard let terminal = Int(value) else {
        throw TextHarnessSocket.Error.malformedLine(line)
    }
    return terminal
}

private final class TextHarnessSocket {
    enum Error: Swift.Error, CustomStringConvertible {
        case streamUnavailable
        case openFailed(String)
        case writeFailed(String)
        case readFailed(String)
        case timedOut(String)
        case malformedLine(String)

        var description: String {
            switch self {
            case .streamUnavailable:
                "Foundation did not create TCP streams"
            case .openFailed(let detail):
                "stream open failed: \(detail)"
            case .writeFailed(let detail):
                "stream write failed: \(detail)"
            case .readFailed(let detail):
                "stream read failed: \(detail)"
            case .timedOut(let detail):
                "timed out: \(detail)"
            case .malformedLine(let line):
                "malformed line: \(line)"
            }
        }
    }

    private let input: InputStream
    private let output: OutputStream
    private var buffer: [UInt8] = []

    init(host: String, port: Int) throws {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)
        guard let inputStream, let outputStream else {
            throw Error.streamUnavailable
        }

        input = inputStream
        output = outputStream
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()
        try waitForOpen()
    }

    func close() {
        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
    }

    func sendLine(_ line: String, timeout: TimeInterval = 5) throws {
        var bytes = Array(line.utf8)
        bytes.append(10)
        var offset = 0
        let deadline = Date().addingTimeInterval(timeout)
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { pointer in
                output.write(pointer.baseAddress!.advanced(by: offset), maxLength: bytes.count - offset)
            }
            if written < 0 {
                throw Error.writeFailed(output.streamError?.localizedDescription ?? "unknown error")
            }
            if written == 0 {
                if Date() >= deadline {
                    throw Error.timedOut("writing line")
                }
                runLoopTick()
            }
            offset += written
        }
    }

    func readLine(containing expected: String, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [String] = []
        while Date() < deadline {
            while let line = popLine() {
                seen.append(line)
                if line.contains(expected) {
                    return line
                }
            }
            try readAvailableBytes()
            runLoopTick()
        }
        throw Error.timedOut("waiting for \(expected), saw \(seen.joined(separator: " | "))")
    }

    private func waitForOpen(timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if input.streamStatus == .error || output.streamStatus == .error {
                throw Error.openFailed(input.streamError?.localizedDescription ?? output.streamError?.localizedDescription ?? "unknown error")
            }
            if input.streamStatus == .open && output.streamStatus == .open {
                return
            }
            runLoopTick()
        }
        throw Error.timedOut("opening TCP streams")
    }

    private func readAvailableBytes() throws {
        guard input.hasBytesAvailable else {
            return
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = input.read(&bytes, maxLength: bytes.count)
        if count < 0 {
            throw Error.readFailed(input.streamError?.localizedDescription ?? "unknown error")
        }
        if count > 0 {
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    private func popLine() -> String? {
        guard let newlineIndex = buffer.firstIndex(of: 10) else {
            return nil
        }
        let lineBytes = buffer[..<newlineIndex]
        buffer.removeSubrange(...newlineIndex)
        return String(decoding: lineBytes, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func runLoopTick() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
