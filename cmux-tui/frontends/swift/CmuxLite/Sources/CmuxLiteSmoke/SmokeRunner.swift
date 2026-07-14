import CmuxLiteCore
import Foundation

struct SmokeRunner: Sendable {
    private let configuration: CmuxConnectionConfiguration
    private let surface: UInt64?

    init(arguments: [String]) throws {
        var connectionArguments: [String] = []
        var parsedSurface: UInt64?
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else {
                throw CmuxProtocolError.invalidArgument("missing value for \(option)")
            }
            let value = arguments[index + 1]
            if option == "--surface" {
                guard let value = UInt64(value) else {
                    throw CmuxProtocolError.invalidArgument("invalid surface id")
                }
                parsedSurface = value
            } else {
                connectionArguments.append(contentsOf: [option, value])
            }
            index += 2
        }

        configuration = try CmuxConnectionConfiguration.parse(
            arguments: connectionArguments,
            readFile: { path in try String(contentsOfFile: path, encoding: .utf8) }
        )
        surface = parsedSurface
    }

    func runWithDeadline() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await runProtocolFlow() }
            group.addTask {
                // This is a genuine smoke-test deadline, not state polling.
                try await ContinuousClock().sleep(for: .seconds(20))
                throw CmuxProtocolError.timedOut("live WebSocket smoke")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func runProtocolFlow() async throws {
        let transport = URLSessionWebSocketTransport(url: configuration.url)
        let client = CmuxProtocolClient(transport: transport)
        let attachmentClientFactory = URLSessionCmuxProtocolClientFactory(
            url: configuration.url
        )
        let frontend = CmuxFrontendSession(
            client: client,
            attachmentClientFactory: attachmentClientFactory,
            configuration: configuration
        )
        let events = await frontend.events()
        defer { Task { await frontend.close() } }

        let startup = try await frontend.connect(
            hostname: ProcessInfo.processInfo.hostName,
            preferredSurface: surface
        )
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
                try await frontend.sendText("echo swift-lite-ok > /tmp/swift-lite.txt\r")
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
}
