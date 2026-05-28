public import Foundation

/// Abstract SSH transport contract that CmuxKit talks to.
///
/// We deliberately keep the surface tiny — one-shot exec, line-streamed exec,
/// raw-stream exec — so tests can stub it without dragging in Citadel and so
/// we can swap transports later (e.g. APNs-relayed sessions, native TLS) with
/// zero churn at the call sites.
public protocol CmuxSSHTransport: Sendable {
    /// Run a remote command, write `stdin` (if any), wait for it to exit, and
    /// return the full stdout + stderr + exit code.
    ///
    /// Use this for short, request/response style commands like
    /// `cmux list-workspaces --json`.
    func runOneShot(
        command: String,
        stdin: Data?
    ) async throws -> CmuxExecResult

    /// Run a remote command and surface its stdout as line-delimited UTF-8
    /// strings as they arrive. Stderr is forwarded to `onStderrLine`.
    ///
    /// Use this for long-lived NDJSON streams like `cmux events --reconnect`.
    ///
    /// Cancellation of the consumer task closes the SSH channel. The function
    /// throws `CmuxError.cancelled` on caller cancellation and
    /// `CmuxError.command(exitCode:stderr:)` on a non-zero remote exit.
    func runLineStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<String, any Error>

    /// Run a remote command and surface stdout as raw bytes (no line
    /// framing). Used for piping captured binary blobs back to the client.
    func runByteStream(
        command: String,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) -> AsyncThrowingStream<Data, any Error>

    /// Light-weight reachability probe: opens a channel, runs `true`, asserts
    /// the SSH transport is still live. Returns the measured round-trip
    /// (useful for keepalive logic).
    func ping() async throws -> Duration

    /// Tear down the SSH session.
    func close() async
}

public struct CmuxExecResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String {
        String(data: stdout, encoding: .utf8) ?? ""
    }

    public var stderrString: String {
        String(data: stderr, encoding: .utf8) ?? ""
    }
}
