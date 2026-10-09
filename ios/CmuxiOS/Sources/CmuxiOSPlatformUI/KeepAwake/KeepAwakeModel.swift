public import CmuxiOSFeatureKit
public import CmuxiOSPlatform
public import Observation

/// Mirrors `KeepAwakeControl` while its screen is visible and sends toggles
/// as intents. A refusal or offline error is shown, never queued.
@MainActor
@Observable
public final class KeepAwakeModel {
    public private(set) var states: [HostID: KeepAwakeState] = [:]
    public private(set) var connection: SourceConnection = .connecting
    public private(set) var busy: Set<HostID> = []
    public private(set) var lastError: String?
    @ObservationIgnored private let control: any KeepAwakeControl

    public init(control: any KeepAwakeControl) { self.control = control }

    /// Runs until the calling task is cancelled (SwiftUI `.task`).
    public func observe() async {
        for await snapshot in await control.updates() {
            states = snapshot.value
            connection = snapshot.connection
        }
    }

    public func set(_ host: HostID, enabled: Bool) async {
        busy.insert(host)
        defer { busy.remove(host) }
        do {
            if case .refused(_, let reason) = try await control.set(host, enabled: enabled, key: IntentKey()) {
                lastError = reason
            } else {
                lastError = nil
            }
        } catch {
            lastError = PlatformText.keepAwakeOffline
        }
    }
}
