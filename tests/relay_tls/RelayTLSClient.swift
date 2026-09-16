import Foundation
import IrohLib

/// A standalone consumer of the exact Iroh framework pinned by the app.
@main
struct RelayTLSClient {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        setLogLevel(level: .debug)
        let relays = try RelayMap.fromUrls(urls: [CommandLine.arguments[1]])
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            relayMode: RelayMode.custom(map: relays),
            portMappingEnabled: false
        ))
        // The parent closes stdin after observing the server's handshake.
        // Blocking is confined to this standalone diagnostic process.
        _ = FileHandle.standardInput.readDataToEndOfFile()
        try await endpoint.close()
    }
}
