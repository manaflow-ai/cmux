import Foundation
import CmuxiOSFeatureKit

/// Fetches the account's remote configuration from the authenticated API.
///
/// Remote flags are deliberately a low-frequency HTTP projection. Terminal,
/// browser and file traffic must stay on their realtime carriers; this source
/// only refreshes the control-plane projection and keeps the last valid value
/// when the API is unavailable. The source never turns a failed response into
/// an empty config, so a transient outage cannot disable an already-enabled
/// surface or accidentally enable a malformed one.
public actor URLSessionRemoteConfigSource: RemoteConfigSource {
    /// The network seam is injectable so decoding, auth and failure behavior
    /// can be tested without a simulator or an API process.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let endpoint: URL
    private let appVersion: String?
    private let token: @Sendable () async throws -> String
    private let initial: RemoteConfig
    private let refreshInterval: Duration
    private let clock: any Clock<Duration>
    private let fetch: Fetch

    /// - Parameters:
    ///   - baseURL: API origin; `/v1/mobile/config` is appended.
    ///   - appVersion: sent to the API's client-version policy gate.
    ///   - initial: cached projection to emit while the first request runs.
    ///   - token: a current Stack session or install-token provider. It is
    ///     called only on the refresh task, never on the caller's hot path.
    ///   - refreshInterval: low-frequency refresh cadence (five minutes by
    ///     default; tests can use a longer interval and cancel the stream).
    ///   - clock: injected for deterministic cancellation and timing tests.
    ///   - fetch: custom request implementation for tests.
    public init(
        baseURL: URL,
        appVersion: String? = nil,
        initial: RemoteConfig = .empty,
        token: @escaping @Sendable () async throws -> String,
        refreshInterval: Duration = .seconds(300),
        clock: any Clock<Duration> = ContinuousClock(),
        fetch: Fetch? = nil
    ) {
        self.endpoint = baseURL.appendingPathComponent("v1/mobile/config")
        self.appVersion = appVersion
        self.initial = initial
        self.token = token
        self.refreshInterval = refreshInterval
        self.clock = clock
        self.fetch = fetch ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteConfigSourceError.invalidResponse
            }
            return (data, http)
        }
    }

    public func updates() async -> AsyncStream<SourceSnapshot<RemoteConfig>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<RemoteConfig>.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let token = self.token
        let endpoint = self.endpoint
        let appVersion = self.appVersion
        let initial = self.initial
        let refreshInterval = self.refreshInterval
        let clock = self.clock
        let fetch = self.fetch
        let task = Task {
            var current = initial
            // `RemoteConfig` can also be constructed by a preview or a
            // stale cache. Clamp before converting: malformed negative
            // revisions must never trap a refresh task.
            var revision = max(Self.safeRevision(current.revision), 1)
            continuation.yield(SourceSnapshot(
                revision: revision,
                value: current,
                connection: .connecting
            ))

            while !Task.isCancelled {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "GET"
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    if let appVersion, !appVersion.isEmpty {
                        request.setValue(appVersion, forHTTPHeaderField: "x-cmux-client-version")
                    }
                    request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 15

                    let (data, response) = try await fetch(request)
                    guard (200..<300).contains(response.statusCode) else {
                        throw RemoteConfigSourceError.http(response.statusCode)
                    }
                    // A remote flag payload is tiny by contract. Refuse an
                    // unexpectedly large response before JSON allocation.
                    guard data.count <= 256 * 1024 else {
                        throw RemoteConfigSourceError.tooLarge
                    }
                    let config = try Self.decode(data)
                    if config != current {
                        current = config
                        revision = max(revision &+ 1, Self.safeRevision(config.revision))
                    }
                    continuation.yield(SourceSnapshot(
                        revision: revision,
                        value: current,
                        connection: .live(path: "https")
                    ))
                } catch is CancellationError {
                    break
                } catch {
                    // Preserve the last valid projection. The shell's cache
                    // and flag precedence remain authoritative while offline.
                    continuation.yield(SourceSnapshot(
                        revision: revision,
                        value: current,
                        connection: .offline(reason: "remote config unavailable")
                    ))
                }

                do {
                    try await clock.sleep(for: refreshInterval)
                } catch {
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func decode(_ data: Data) throws -> RemoteConfig {
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        guard envelope.ok else { throw RemoteConfigSourceError.refused }
        let value = envelope.value
        return RemoteConfig(
            revision: max(value.version ?? 0, 0),
            flags: value.flags ?? [:],
            minimumMacProtocol: value.minimumMacProtocol,
            whatsNewRevision: value.whatsNewRevision,
            demoContent: value.demoContent ?? false
        )
    }

    private static func safeRevision(_ value: Int) -> UInt64 {
        UInt64(max(value, 0))
    }
}

public enum RemoteConfigSourceError: Error, Equatable, Sendable {
    case invalidResponse
    case http(Int)
    case tooLarge
    case refused
}

private struct WireEnvelope: Decodable, Sendable {
    let ok: Bool
    let value: WireConfig
}

private struct WireConfig: Decodable, Sendable {
    let version: Int?
    let flags: [String: RemoteFlagValue]?
    let minAppVersion: String?
    let minimumMacProtocol: Int?
    let whatsNewRevision: Int?
    let demoContent: Bool?

    private enum CodingKeys: String, CodingKey {
        case version, flags
        case minAppVersion = "min_app_version"
        case minimumMacProtocol, whatsNewRevision, demoContent
    }
}
