import Darwin
import Foundation
import Testing

/// `cmux set-buffer` stores exactly the text it is given, including trailing
/// newlines and indentation, and reads that text from stdin when no text
/// argument is passed, so `cmd | cmux set-buffer` works like tmux.
@Suite(.serialized)
struct CLITmuxCompatBufferContentTests {
    @Test func setBufferReadsStandardInputVerbatim() throws {
        let text = "first line\n  indented line\n\n"
        let run = try runSetBuffer(arguments: ["set-buffer", "--name", "piped"], standardInput: text)

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.buffers?["piped"] == text)
    }

    @Test func setBufferDashReadsStandardInput() throws {
        let run = try runSetBuffer(arguments: ["set-buffer", "--name", "dash", "-"], standardInput: "from stdin\n")

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.buffers?["dash"] == "from stdin\n")
    }

    @Test func setBufferKeepsTrailingNewlineAndSpacesFromArguments() throws {
        let run = try runSetBuffer(arguments: ["set-buffer", "--name", "arg", "--", "  echo hi\n"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        #expect(run.buffers?["arg"] == "  echo hi\n")
    }

    @Test func setBufferWithEmptyStandardInputFailsWithoutWriting() throws {
        let run = try runSetBuffer(arguments: ["set-buffer", "--name", "empty"], standardInput: "")

        #expect(run.result.status != 0)
        #expect(run.buffers?["empty"] == nil)
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let buffers: [String: String]?
    }

    private func runSetBuffer(arguments: [String], standardInput: String? = nil) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-tmux-buffer-content-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let storeURL = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("tmux-compat-store.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = makeCodexHookSocketPath("setbuf")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let drain = Self.startClientDrain(listenerFD: listenerFD)
        defer {
            drain.stop.set()
            _ = drain.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            standardInput: standardInput,
            timeout: 60
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))

        var buffers: [String: String]?
        if let data = try? Data(contentsOf: storeURL),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            buffers = object["buffers"] as? [String: String]
        }
        return Run(result: result, buffers: buffers)
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// Accepts and immediately closes clients until stopped; set-buffer only
    /// touches the local store, so no socket replies are needed.
    private static func startClientDrain(listenerFD: Int32) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var descriptor = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD >= 0 { Darwin.close(clientFD) }
            }
        }
        return (done, stop)
    }
}
