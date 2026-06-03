import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "mobile.analytics")

enum MobileAnalyticsEventName: String, Codable, Equatable, Sendable {
    case mobileMachineSessionIssued = "mobile_machine_session_issued"
    case mobileHeartbeatIngested = "mobile_heartbeat_ingested"
    case mobileWorkspaceSnapshotIngested = "mobile_workspace_snapshot_ingested"
    case mobileWorkspaceOpened = "mobile_workspace_opened"
    case mobileWorkspaceMarkRead = "mobile_workspace_mark_read"
    case mobilePushRegistered = "mobile_push_registered"
    case mobilePushRemoved = "mobile_push_removed"
    case mobilePushTestSent = "mobile_push_test_sent"
    case mobilePushOpened = "mobile_push_opened"
    case mobileDaemonTicketIssued = "mobile_daemon_ticket_issued"
    case mobileDaemonAttachResult = "mobile_daemon_attach_result"
    case iosGRDBBootCompleted = "ios_grdb_boot_completed"
}

enum MobileAnalyticsTeamKind: String, Codable, Equatable, Sendable {
    case personal
    case shared
}

struct MobileAnalyticsProperties: Encodable, Equatable, Sendable {
    let teamId: String?
    let teamKind: MobileAnalyticsTeamKind?
    let userId: String?
    let machineId: String?
    let workspaceId: String?
    let platform: String?
    let bundleId: String?
    let source: String?
    let result: String?
    let errorCode: String?
    let latencyMs: Int?
    let cacheAgeMs: Int?
    let workspaceCount: Int?
    let unreadCount: Int?

    init(
        teamId: String? = nil,
        teamKind: MobileAnalyticsTeamKind? = nil,
        userId: String? = nil,
        machineId: String? = nil,
        workspaceId: String? = nil,
        platform: String? = nil,
        bundleId: String? = nil,
        source: String? = nil,
        result: String? = nil,
        errorCode: String? = nil,
        latencyMs: Int? = nil,
        cacheAgeMs: Int? = nil,
        workspaceCount: Int? = nil,
        unreadCount: Int? = nil
    ) {
        self.teamId = teamId
        self.teamKind = teamKind
        self.userId = userId
        self.machineId = machineId
        self.workspaceId = workspaceId
        self.platform = platform
        self.bundleId = bundleId
        self.source = source
        self.result = result
        self.errorCode = errorCode
        self.latencyMs = latencyMs
        self.cacheAgeMs = cacheAgeMs
        self.workspaceCount = workspaceCount
        self.unreadCount = unreadCount
    }

    func withDefaults(platform: String, bundleId: String?) -> Self {
        Self(
            teamId: teamId,
            teamKind: teamKind,
            userId: userId,
            machineId: machineId,
            workspaceId: workspaceId,
            platform: self.platform ?? platform,
            bundleId: self.bundleId ?? bundleId,
            source: source,
            result: result,
            errorCode: errorCode,
            latencyMs: latencyMs,
            cacheAgeMs: cacheAgeMs,
            workspaceCount: workspaceCount,
            unreadCount: unreadCount
        )
    }
}

private struct MobileAnalyticsCaptureRequest: Encodable, Equatable, Sendable {
    let event: MobileAnalyticsEventName
    let properties: MobileAnalyticsProperties
}

@MainActor
protocol MobileAnalyticsTracking {
    func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties)
}

@MainActor
final class MobileAnalyticsClient: MobileAnalyticsTracking {
    private let transport: MobileAuthenticatedRouteTransport
    private let platform: String
    private let bundleId: String?

    init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil,
        platform: String = "ios",
        bundleId: String? = Bundle.main.bundleIdentifier
    ) {
        self.transport = MobileAuthenticatedRouteTransport(
            baseURL: baseURL,
            session: session,
            authManager: authManager
        )
        self.platform = platform
        self.bundleId = bundleId
    }

    func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties) {
        guard transport.isAuthenticated else { return }
        let payload = MobileAnalyticsCaptureRequest(
            event: event,
            properties: properties.withDefaults(platform: platform, bundleId: bundleId)
        )

        Task {
            do {
                _ = try await transport.send(
                    path: "api/mobile/analytics",
                    body: payload,
                    responseType: MobileAcceptedResponse.self
                )
            } catch {
                log.error("Failed to capture \(event.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
