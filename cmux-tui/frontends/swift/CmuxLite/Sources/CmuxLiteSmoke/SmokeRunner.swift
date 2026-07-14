import CmuxLiteCore
import Darwin
import Foundation

struct SmokeRunner: Sendable {
    private let configuration: CmuxConnectionConfiguration
    private let benchmarkWebSocketConfiguration: CmuxConnectionConfiguration?
    private let surface: UInt64?
    private let benchmarkIterations: Int?
    private let useURLSession: Bool

    init(arguments: [String]) throws {
        var connectionArguments: [String] = []
        var parsedSurface: UInt64?
        var parsedBenchmarkIterations: Int?
        var parsedUseURLSession = false
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            if option == "--benchmark" {
                parsedBenchmarkIterations = parsedBenchmarkIterations ?? 200
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw CmuxProtocolError.invalidArgument("missing value for \(option)")
            }
            let value = arguments[index + 1]
            if option == "--surface" {
                guard let value = UInt64(value) else {
                    throw CmuxProtocolError.invalidArgument("invalid surface id")
                }
                parsedSurface = value
            } else if option == "--iterations" {
                guard let value = Int(value), value > 0 else {
                    throw CmuxProtocolError.invalidArgument("iterations must be positive")
                }
                parsedBenchmarkIterations = value
            } else if option == "--transport" {
                guard value == "network" || value == "urlsession" else {
                    throw CmuxProtocolError.invalidArgument(
                        "transport must be network or urlsession"
                    )
                }
                parsedUseURLSession = value == "urlsession"
            } else {
                connectionArguments.append(contentsOf: [option, value])
            }
            index += 2
        }

        if parsedBenchmarkIterations != nil {
            let unixArguments = Self.connectionArguments(
                connectionArguments,
                excluding: ["--url", "--token", "--token-file"]
            )
            var webSocketArguments = Self.connectionArguments(
                connectionArguments,
                excluding: ["--socket", "--session"]
            )
            if !webSocketArguments.contains("--url") {
                webSocketArguments.append(contentsOf: [
                    "--url", CmuxConnectionConfiguration.defaultURL.absoluteString,
                ])
            }
            configuration = try Self.parseConnection(unixArguments)
            benchmarkWebSocketConfiguration = try Self.parseConnection(webSocketArguments)
        } else {
            configuration = try Self.parseConnection(connectionArguments)
            benchmarkWebSocketConfiguration = nil
        }
        surface = parsedSurface
        benchmarkIterations = parsedBenchmarkIterations
        useURLSession = parsedUseURLSession
    }

    func runWithDeadline() async throws {
        let deadline: Duration = benchmarkIterations == nil ? .seconds(20) : .seconds(120)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runProtocolFlow() }
            group.addTask {
                // This is a genuine smoke-test deadline, not state polling.
                try await ContinuousClock().sleep(for: deadline)
                throw CmuxProtocolError.timedOut(
                    String(
                        localized: "smoke.timeout",
                        defaultValue: "Live transport smoke",
                        bundle: .module
                    )
                )
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func runProtocolFlow() async throws {
        if let iterations = benchmarkIterations,
           let webSocketConfiguration = benchmarkWebSocketConfiguration
        {
            let unix = try await measureLatency(
                configuration: configuration,
                iterations: iterations
            )
            let webSocket = try await measureLatency(
                configuration: webSocketConfiguration,
                iterations: iterations
            )
            printLatencyTable(
                iterations: iterations,
                unix: unix,
                webSocket: webSocket
            )
            return
        }

        let frontend = makeFrontend(configuration: configuration)
        let events = await frontend.events()
        do {
            let startup = try await frontend.connect(
                hostname: ProcessInfo.processInfo.hostName,
                preferredSurface: surface
            )
            try await runMarkerSmoke(frontend: frontend, events: events, startup: startup)
            await frontend.close()
        } catch {
            await frontend.close()
            throw error
        }
    }

    private func runMarkerSmoke(
        frontend: CmuxFrontendSession,
        events: AsyncStream<CmuxFrontendEvent>,
        startup: CmuxFrontendStartup
    ) async throws {
        print("identify app=cmux-tui protocol=\(startup.protocolVersion) surface=\(startup.surface)")

        var receivedReplay = false
        var markerBuffer = Data()
        let marker = Data("cmux-lite-done".utf8)

        for await frontendEvent in events {
            guard case let .terminal(event) = frontendEvent else { continue }
            switch event {
            case let .initialReplay(_, columns, rows, bytes, _):
                print("received vt-state cols=\(columns) rows=\(rows) bytes=\(bytes.count)")
                receivedReplay = true
                try await frontend.sendText(
                    "\u{3}\u{15}echo swift-lite-ok > /tmp/swift-lite.txt\r"
                )
                try await frontend.sendText(
                    "printf '\\143\\155\\165\\170\\55\\154\\151\\164\\145\\55\\144\\157\\156\\145\\12'\r"
                )
                print("send responses ok")
            case let .output(_, bytes) where receivedReplay:
                markerBuffer.append(bytes)
                if markerBuffer.count > 65_536 {
                    markerBuffer.removeFirst(markerBuffer.count - 65_536)
                }
                if markerBuffer.range(of: marker) != nil {
                    let contents = try String(
                        contentsOfFile: "/tmp/swift-lite.txt",
                        encoding: .utf8
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard contents == "swift-lite-ok" else {
                        throw CmuxProtocolError.malformedPayload(
                            "unexpected /tmp/swift-lite.txt contents: \(contents)"
                        )
                    }
                    print("observed output marker cmux-lite-done")
                    print("/tmp/swift-lite.txt=\(contents)")
                    return
                }
            case .detached:
                throw CmuxProtocolError.transportState("surface detached during smoke")
            case .resizedReplay, .output, .colorsChanged, .other:
                break
            }
        }

        throw CmuxProtocolError.transportState("event stream ended during smoke")
    }

    private func measureLatency(
        configuration: CmuxConnectionConfiguration,
        iterations: Int
    ) async throws -> (p50: Double, p95: Double, maximum: Double, surface: UInt64) {
        let frontend = makeFrontend(configuration: configuration)
        let events = await frontend.events()
        do {
            let startup = try await frontend.connect(
                hostname: ProcessInfo.processInfo.hostName,
                preferredSurface: surface
            )
            let samples = try await runLatencySuite(
                frontend: frontend,
                events: events,
                iterations: iterations
            )
            await frontend.close()
            return (
                p50: Self.percentile(50, samples: samples),
                p95: Self.percentile(95, samples: samples),
                maximum: samples.last ?? 0,
                surface: startup.surface
            )
        } catch {
            await frontend.close()
            throw error
        }
    }

    private func runLatencySuite(
        frontend: CmuxFrontendSession,
        events: AsyncStream<CmuxFrontendEvent>,
        iterations: Int
    ) async throws -> [Double] {
        var iterator = events.makeAsyncIterator()
        try await waitForInitialReplay(from: &iterator)

        let marker = Data("cmux-lite-benchmark-ready".utf8)
        try await frontend.sendText(
            "\u{3}bash -c 'printf \"\\143\\155\\165\\170\\055\\154\\151\\164\\145\\055\\142\\145\\156\\143\\150\\155\\141\\162\\153\\055\\162\\145\\141\\144\\171\\012\"; exec cat'\r"
        )
        try await waitForMarker(marker, occurrences: 1, from: &iterator)

        let clock = ContinuousClock()
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)

        do {
            for index in 0..<iterations {
                let byte = characters[index % characters.count]
                let payload = Data([byte])
                let start = clock.now
                let sendTask = Task {
                    await frontend.sendInput(payload)
                }
                try await waitForEcho(byte, from: &iterator)
                let elapsed = start.duration(to: clock.now)
                await sendTask.value
                samples.append(Self.milliseconds(elapsed))
            }
        } catch {
            await frontend.sendInput(Data([3]))
            throw error
        }

        await frontend.sendInput(Data([3]))
        samples.sort()
        return samples
    }

    private func makeFrontend(
        configuration: CmuxConnectionConfiguration
    ) -> CmuxFrontendSession {
        let transport: any CmuxTransport
        let attachmentClientFactory: any CmuxProtocolClientFactory
        switch configuration.endpoint {
        case let .unixSocket(path):
            transport = UnixSocketTransport(path: path)
            attachmentClientFactory = ConfiguredCmuxProtocolClientFactory(
                endpoint: configuration.endpoint
            )
        case let .webSocket(url):
            if useURLSession {
                transport = URLSessionWebSocketTransport(url: url)
                attachmentClientFactory = URLSessionCmuxProtocolClientFactory(url: url)
            } else {
                transport = NetworkWebSocketTransport(url: url)
                attachmentClientFactory = NetworkCmuxProtocolClientFactory(url: url)
            }
        }

        return CmuxFrontendSession(
            client: CmuxProtocolClient(transport: transport),
            attachmentClientFactory: attachmentClientFactory,
            configuration: configuration
        )
    }

    private func printLatencyTable(
        iterations: Int,
        unix: (p50: Double, p95: Double, maximum: Double, surface: UInt64),
        webSocket: (p50: Double, p95: Double, maximum: Double, surface: UInt64)
    ) {
        print(String(
            format: String(
                localized: "smoke.benchmark.summary",
                defaultValue: "Echo RTT iterations=%1$lld unix-surface=%2$llu websocket-surface=%3$llu",
                bundle: .module
            ),
            Int64(iterations),
            unix.surface,
            webSocket.surface
        ))
        print(
            String(
                localized: "smoke.benchmark.columns",
                defaultValue: "metric | unix socket | websocket",
                bundle: .module
            )
        )
        print(String(format: "p50    | %8.3f ms | %8.3f ms", unix.p50, webSocket.p50))
        print(String(format: "p95    | %8.3f ms | %8.3f ms", unix.p95, webSocket.p95))
        print(String(
            format: String(
                localized: "smoke.benchmark.maximum",
                defaultValue: "max    | %1$8.3f ms | %2$8.3f ms",
                bundle: .module
            ),
            unix.maximum,
            webSocket.maximum
        ))
    }

    private func waitForInitialReplay(
        from iterator: inout AsyncStream<CmuxFrontendEvent>.AsyncIterator
    ) async throws {
        while let event = await iterator.next() {
            if case .terminal(.initialReplay) = event {
                return
            }
        }
        throw CmuxProtocolError.transportState("event stream ended before initial replay")
    }

    private func waitForMarker(
        _ marker: Data,
        occurrences: Int,
        from iterator: inout AsyncStream<CmuxFrontendEvent>.AsyncIterator
    ) async throws {
        var remaining = occurrences
        var buffer = Data()
        while let event = await iterator.next() {
            guard case let .terminal(.output(_, bytes)) = event else { continue }
            buffer.append(bytes)
            while let range = buffer.range(of: marker) {
                remaining -= 1
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if remaining == 0 { return }
            }
            if buffer.count > marker.count * 2 {
                buffer.removeFirst(buffer.count - marker.count * 2)
            }
        }
        throw CmuxProtocolError.transportState("event stream ended before benchmark marker")
    }

    private func waitForEcho(
        _ byte: UInt8,
        from iterator: inout AsyncStream<CmuxFrontendEvent>.AsyncIterator
    ) async throws {
        while let event = await iterator.next() {
            guard case let .terminal(.output(_, bytes)) = event else { continue }
            if bytes.contains(byte) { return }
        }
        throw CmuxProtocolError.transportState("event stream ended before benchmark echo")
    }

    private static func parseConnection(
        _ arguments: [String]
    ) throws -> CmuxConnectionConfiguration {
        try CmuxConnectionConfiguration.parse(
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            userID: getuid(),
            readFile: { path in try String(contentsOfFile: path, encoding: .utf8) },
            listDirectory: { directory in
                try FileManager.default.contentsOfDirectory(atPath: directory).map {
                    URL(fileURLWithPath: directory, isDirectory: true)
                        .appendingPathComponent($0, isDirectory: false)
                        .path
                }
            }
        )
    }

    private static func connectionArguments(
        _ arguments: [String],
        excluding excludedOptions: Set<String>
    ) -> [String] {
        var filtered: [String] = []
        var index = 0
        while index + 1 < arguments.count {
            if !excludedOptions.contains(arguments[index]) {
                filtered.append(arguments[index])
                filtered.append(arguments[index + 1])
            }
            index += 2
        }
        return filtered
    }

    private static func percentile(_ value: Int, samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let rank = Int(ceil(Double(value) / 100 * Double(samples.count))) - 1
        return samples[max(0, min(rank, samples.count - 1))]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
