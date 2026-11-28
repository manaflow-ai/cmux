import Foundation
import IrohLib

/// A standalone consumer of the exact Iroh framework pinned by the app.
@main
struct RelayTLSClient {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        setLogLevel(level: .off)
        let relays = try RelayMap.fromUrls(urls: [CommandLine.arguments[1]])
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(),
            relayMode: RelayMode.custom(map: relays),
            portMappingEnabled: false
        ))
        #if RELAY_TLS_DIAGNOSTICS
        let watch = endpoint.watchRelayConnectionDiagnostics(callback: RelayTLSProbeObserver())
        #endif
        // The parent closes stdin after observing the server's handshake.
        // Blocking is confined to this standalone diagnostic process.
        _ = await Task.detached {
            FileHandle.standardInput.readDataToEndOfFile()
        }.value
        #if RELAY_TLS_DIAGNOSTICS
        await watch.stop()
        #endif
        try await endpoint.close()
        #if RELAY_TLS_DIAGNOSTICS
        // Readiness closes a timed-out endpoint before presenting its error.
        // Its direct snapshot must retain the cause without a callback cache.
        try RelayTLSProbeObserver.write(endpoint.relayConnectionDiagnostics(), prefix: "FINAL_DIAGNOSTIC")
        #endif
    }
}

#if RELAY_TLS_DIAGNOSTICS
private actor RelayTLSProbeObserver: RelayConnectionDiagnosticCallback {
    func onChange(diagnostics: [RelayConnectionDiagnostic]) async throws {
        try Self.write(diagnostics, prefix: "DIAGNOSTIC")
    }

    static func write(_ diagnostics: [RelayConnectionDiagnostic], prefix: String) throws {
        for snapshot in diagnostics {
            guard let failure = snapshot.failure else { continue }
            let data = try JSONSerialization.data(withJSONObject: [
                "host": snapshot.host,
                "cause": String(describing: failure),
            ], options: [.sortedKeys])
            // A single write keeps the parent's diagnostic line atomic.
            FileHandle.standardOutput.write(Data("\(prefix) ".utf8) + data + Data("\n".utf8))
        }
    }
}
#endif
