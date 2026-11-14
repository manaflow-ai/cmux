import CmuxRemoteDaemon
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteTmuxSSHStreamClientTests {
    @Test func streamClientRoundTripsAcrossClosedStreamLifecycles() async throws {
        let fixture = try makeEchoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let client = RemoteTmuxSSHStreamClient(
            host: RemoteTmuxHost(destination: "fixture@localhost"),
            sshExecutablePath: fixture.executable.path,
            controlPersistSeconds: 1
        )

        let first = try client.openStream(host: "127.0.0.1", port: 8080, timeoutMs: 1_000)
        try await assertRoundTrip(Data("first stream".utf8), streamID: first, client: client)
        client.closeStream(streamID: first)

        let second = try client.openStream(host: "127.0.0.1", port: 8080, timeoutMs: 1_000)
        try await assertRoundTrip(Data("second stream".utf8), streamID: second, client: client)
        client.closeStream(streamID: second)
    }

    private func assertRoundTrip(
        _ expected: Data,
        streamID: String,
        client: RemoteTmuxSSHStreamClient
    ) async throws {
        let (events, continuation) = AsyncStream<RemoteDaemonStreamEvent>.makeStream()
        defer { continuation.finish() }
        try client.attachStream(streamID: streamID, queue: DispatchQueue(label: "cmux.test.remote-tmux-ssh-stream")) {
            continuation.yield($0)
        }
        try client.writeStream(streamID: streamID, data: expected)

        var received = Data()
        for await event in events {
            switch event {
            case .data(let data), .eof(let data):
                received.append(data)
                if received == expected { return }
            case .error(let detail):
                throw RemoteTmuxError.unreachable("echo fixture stream failed: \(detail)")
            }
        }
        throw RemoteTmuxError.unreachable("echo fixture stream ended before returning its payload")
    }

    private func makeEchoFixture() throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-tmux-ssh-stream-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("ssh")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }
}
