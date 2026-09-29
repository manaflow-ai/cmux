import Darwin
import Foundation
import Testing

/// `cmux remotes add` route parsing, per issue #15670.
///
/// `--route=value` used to be silently discarded (and a lone `--route=value`
/// produced the misleading "requires at least one --route" error), a typo such
/// as `--rouet=...` disappeared entirely, and mixing split and equals forms
/// sent only the first route to `remotes.add`. These tests pin exit behavior
/// and the captured RPC parameters for split, equals, mixed, typo and
/// missing-value cases, plus terminator handling.
@Suite(.serialized)
struct CLIRemotesAddRouteParsingTests {
    private static let timeout: TimeInterval = 60

    // MARK: - Cases

    @Test func splitFormSendsTheRoute() throws {
        let run = try runRemotesAdd(arguments: ["remotes", "add", "fixture", "--route", "100.64.1.2:51001"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(try Self.remotesAddParams(run))
        #expect(params["name"] as? String == "fixture")
        #expect(params["routes"] as? [String] == ["100.64.1.2:51001"])
    }

    @Test func equalsFormSendsTheRoute() throws {
        let run = try runRemotesAdd(arguments: ["remotes", "add", "fixture", "--route=100.64.1.2:51001"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(try Self.remotesAddParams(run))
        #expect(params["routes"] as? [String] == ["100.64.1.2:51001"])
    }

    @Test func mixedFormsSendEveryRouteInOrder() throws {
        let run = try runRemotesAdd(
            arguments: [
                "remotes", "add", "fixture",
                "--route", "100.64.1.2:51001",
                "--route=100.64.1.3:51001",
            ])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(try Self.remotesAddParams(run))
        #expect(
            params["routes"] as? [String] == ["100.64.1.2:51001", "100.64.1.3:51001"],
            Comment(rawValue: run.result.stdout + run.result.stderr))
    }

    @Test func typoedOptionIsRefusedInsteadOfSilentlyDropped() throws {
        let run = try runRemotesAdd(
            arguments: [
                "remotes", "add", "fixture",
                "--route", "100.64.1.2:51001",
                "--rouet=100.64.1.3:51001",
            ])

        #expect(run.result.status != 0)
        #expect(
            run.result.stderr.contains("unknown option"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(try Self.remotesAddParams(run) == nil, "no mutation request may be sent")
    }

    @Test func missingRouteValueIsRefusedClearly() throws {
        let run = try runRemotesAdd(arguments: ["remotes", "add", "fixture", "--route"])

        #expect(run.result.status != 0)
        #expect(
            run.result.stderr.contains("--route requires a value"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(try Self.remotesAddParams(run) == nil, "no mutation request may be sent")
    }

    @Test func equalsOnlyRouteSatisfiesTheAtLeastOneRouteRequirement() throws {
        let run = try runRemotesAdd(arguments: ["remotes", "add", "fixture", "--route=100.64.1.2:51001"])

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        #expect(
            !run.result.stderr.contains("requires at least one --route"),
            Comment(rawValue: run.result.stderr + run.result.stdout))
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]
    }

    private static func remotesAddParams(_ run: Run) throws -> [String: Any]? {
        let request = run.requests.first { $0["method"] as? String == "remotes.add" }
        return request?["params"] as? [String: Any]
    }

    private func runRemotesAdd(arguments: [String]) throws -> Run {
        let socketPath = makeCodexHookSocketPath("remotes-add")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(listenerFD: listenerFD, recorder: recorder)
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
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
                "HOME": NSHomeDirectory(),
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
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

    /// Accepts clients until `stop` is set and answers every v2 request with
    /// a fixture `remotes.add`-style result. Polls instead of blocking in
    /// accept so the loop exits deterministically when the test finishes.
    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder)
            }
        }
        return (done, stop)
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let id = (codexHookJSONObject(line)?["id"] as? String) ?? "unknown"
                let response = codexHookV2Response(
                    id: id,
                    ok: true,
                    result: ["deviceId": "33333333-3333-3333-3333-333333333333"]
                )
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
