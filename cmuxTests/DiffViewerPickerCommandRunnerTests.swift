import CmuxBrowser
import CmuxFoundation
import Darwin
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct DiffViewerPickerCommandRunnerTests {
    @Test(.timeLimit(.minutes(1)))
    func rejectsPickerCommandsBeyondConcurrencyLimitAndReusesCapacity() async throws {
        let commands = ControllablePickerCommands()
        let runner = DiffViewerPickerCommandRunner(
            commandRunner: commands,
            executablePath: "/test/cmux",
            concurrencyLimit: 2
        )
        var starts = commands.starts.makeAsyncIterator()

        let first = Task { await runner.run(arguments: ["first"]) }
        let firstStarted = try #require(await starts.next())
        let second = Task { await runner.run(arguments: ["second"]) }
        let secondStarted = try #require(await starts.next())

        #expect(await runner.run(arguments: ["rejected"]) == nil)
        #expect(await commands.startedIDs == ["first", "second"])

        await commands.complete(firstStarted)
        await commands.complete(secondStarted)
        let outputs = await [first.value, second.value]
        #expect(outputs.allSatisfy { $0 != nil })
        #expect(await commands.maximumActiveCount == 2)

        let subsequent = Task { await runner.run(arguments: ["subsequent"]) }
        let subsequentStarted = try #require(await starts.next())
        await commands.complete(subsequentStarted)
        #expect(await subsequent.value == "subsequent")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingActivePickerCommandReleasesCapacity() async throws {
        let commands = ControllablePickerCommands()
        let runner = DiffViewerPickerCommandRunner(
            commandRunner: commands,
            executablePath: "/test/cmux",
            concurrencyLimit: 1
        )
        var starts = commands.starts.makeAsyncIterator()
        var cancellations = commands.cancellations.makeAsyncIterator()

        let active = Task { await runner.run(arguments: ["active"]) }
        let activeID = try #require(await starts.next())
        active.cancel()

        #expect(await cancellations.next() == activeID)
        #expect(await active.value == nil)
        #expect(await commands.startedIDs == ["active"])

        let subsequent = Task { await runner.run(arguments: ["subsequent"]) }
        let subsequentID = try #require(await starts.next())
        await commands.complete(subsequentID)
        #expect(await subsequent.value == "subsequent")
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingPickerSchemeTaskCancelsRunningCommand() async throws {
        let commands = ControllablePickerCommands()
        let runner = DiffViewerPickerCommandRunner(
            commandRunner: commands,
            executablePath: "/test/cmux",
            concurrencyLimit: 1
        )
        let fixture = try await makePickerFixture(runner: runner)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var starts = commands.starts.makeAsyncIterator()
        var cancellations = commands.cancellations.makeAsyncIterator()
        let schemeTask = PickerRecordingSchemeTask(request: URLRequest(url: fixture.requestURL))

        fixture.handler.webView(fixture.webView, start: schemeTask)
        let started = try #require(await starts.next())
        #expect(started == "picker")

        fixture.handler.webView(fixture.webView, stop: schemeTask)

        let cancelled = try #require(await cancellations.next())
        #expect(cancelled == "picker")
        #expect(schemeTask.callbackCount == 0)
    }

    private func makePickerFixture(runner: DiffViewerPickerCommandRunner) async throws -> (
        handler: CmuxDiffViewerURLSchemeHandler,
        webView: WKWebView,
        rootURL: URL,
        requestURL: URL
    ) {
        let token = UUID().uuidString.lowercased()
        let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = rootURL.appendingPathComponent("index.html", isDirectory: false)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "<!doctype html><title>picker cancellation</title>"
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let handler = CmuxDiffViewerURLSchemeHandler(pickerCommandRunner: runner)
        try await handler.register(
            token: token,
            files: [.init(requestPath: "/index.html", fileURL: fileURL, mimeType: "text/html")]
        )
        var components = URLComponents()
        components.scheme = CmuxDiffViewerURLSchemeHandler.scheme
        components.host = token
        components.path = "/__cmux_diff_viewer_refs"
        components.queryItems = [URLQueryItem(name: "repo", value: rootURL.path)]
        let requestURL = try #require(components.url)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        return (handler, webView, rootURL, requestURL)
    }
}

private actor ControllablePickerCommands: CommandRunning {
    let starts: AsyncStream<String>
    let cancellations: AsyncStream<String>

    private let startContinuation: AsyncStream<String>.Continuation
    private let cancellationContinuation: AsyncStream<String>.Continuation
    private var completions: [String: CheckedContinuation<Void, Never>] = [:]
    private var cancelledBeforeRegistration: Set<String> = []
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var startedIDs: [String] = []

    init() {
        (starts, startContinuation) = AsyncStream.makeStream()
        (cancellations, cancellationContinuation) = AsyncStream.makeStream()
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let id = arguments.count == 1 ? arguments[0] : "picker"
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        startedIDs.append(id)
        startContinuation.yield(id)

        if !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || cancelledBeforeRegistration.remove(id) != nil {
                        continuation.resume()
                    } else {
                        completions[id] = continuation
                    }
                }
            } onCancel: {
                Task {
                    await self.cancel(id: id)
                }
            }
        }

        activeCount -= 1
        if Task.isCancelled {
            cancellationContinuation.yield(id)
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: "cancelled"
            )
        }
        return CommandResult(
            stdout: id,
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func complete(_ id: String) {
        completions.removeValue(forKey: id)?.resume()
    }

    private func cancel(id: String) {
        if let continuation = completions.removeValue(forKey: id) {
            continuation.resume()
        } else {
            cancelledBeforeRegistration.insert(id)
        }
    }
}

private final class PickerRecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var callbackCount = 0

    init(request: URLRequest) {
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        callbackCount += 1
    }

    func didReceive(_ data: Data) {
        callbackCount += 1
    }

    func didFinish() {
        callbackCount += 1
    }

    func didFailWithError(_ error: Error) {
        callbackCount += 1
    }
}
