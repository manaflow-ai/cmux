import SwiftUI
import CmuxKit
import Logging
import os
import BackgroundTasks
import UserNotifications

@main
struct CmuxRemoteApp: App {
    @UIApplicationDelegateAdaptor(CmuxRemoteAppDelegate.self) private var appDelegate

    @StateObject private var hostStore = HostStore.shared
    @StateObject private var connectionManager = ConnectionManager.shared
    @StateObject private var notificationsBridge = NotificationCenterBridge.shared
    @StateObject private var liveActivityController = CMUXLiveActivityController.shared
    @StateObject private var keyboardShortcutBus = KeyboardShortcutBus.shared

    @Environment(\.scenePhase) private var scenePhase

    init() {
        LoggingSystem.bootstrap { label in
            OSLogHandler(label: label)
        }
        CmuxRemoteIntentHandlers.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(hostStore)
                .environmentObject(connectionManager)
                .environmentObject(notificationsBridge)
                .environmentObject(liveActivityController)
                .environmentObject(keyboardShortcutBus)
                .task {
                    await notificationsBridge.requestAuthorization()
                    await connectionManager.bind(notifications: notificationsBridge,
                                                 liveActivity: liveActivityController)
                    if let active = hostStore.activeHost {
                        await connectionManager.connect(to: active)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handlePhase(newPhase)
        }
    }

    private func handlePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await connectionManager.handleEnterForeground() }
        case .inactive:
            break
        case .background:
            Task { await connectionManager.handleEnterBackground() }
            BGScheduler.shared.scheduleAll()
        @unknown default:
            break
        }
    }
}

enum CmuxRemoteIntentHandlers {
    @MainActor
    static func install() {
        CmuxIntentResolverRegistry.registerResolveDecision { request in
            await resolve(request)
        }
    }

    @MainActor
    private static func resolve(_ request: CmuxIntentResolverRegistry.DecisionResolveRequest) async -> CmuxIntentResolverRegistry.Result {
        guard let kind = AgentDecision.Kind(rawValue: request.decisionKind) else {
            return .failed(message: L10n.format(
                "intent.resolve_decision.unknown_kind",
                defaultValue: "Unknown decision kind %@",
                request.decisionKind
            ))
        }
        guard let itemID = request.itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !itemID.isEmpty else {
            return .failed(message: L10n.string(
                "intent.resolve_decision.missing_item",
                defaultValue: "This remote decision is missing its feed item. Open cmux to resolve it."
            ))
        }
        do {
            try await ConnectionManager.shared.resolveAgentDecision(
                decisionID: request.decisionID,
                hostID: request.hostID.flatMap(UUID.init(uuidString:)),
                itemID: itemID,
                kind: kind,
                choiceID: request.choiceID,
                choiceLabel: request.choiceLabel,
                questionSelections: request.questionSelections
            )
            await NotificationCenterBridge.shared.clearAgentDecision(
                decisionID: request.decisionID,
                hostID: request.hostID.flatMap(UUID.init(uuidString:))
            )
            return .delivered
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}

/// Forwards swift-log messages to the unified system log so they show up in
/// Console.app and Xcode's debug area, with the cmux subsystem tag.
struct OSLogHandler: LogHandler {
    let label: String
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    private let logger: os.Logger

    init(label: String) {
        self.label = label
        self.logger = os.Logger(subsystem: "com.cmuxterm.remote", category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        log(
            level: event.level,
            message: event.message,
            metadata: event.metadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line
        )
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicit: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = self.metadata.merging(explicit ?? [:]) { _, new in new }
        let rendered = merged.isEmpty
            ? message.description
            : "\(message.description) \(merged)"
        switch level {
        case .trace, .debug:
            #if DEBUG
            logger.debug("\(rendered, privacy: .public)")
            #else
            logger.debug("\(rendered, privacy: .private)")
            #endif
        case .info, .notice:
            #if DEBUG
            logger.info("\(rendered, privacy: .public)")
            #else
            logger.info("\(rendered, privacy: .private)")
            #endif
        case .warning:
            #if DEBUG
            logger.warning("\(rendered, privacy: .public)")
            #else
            logger.warning("\(rendered, privacy: .private)")
            #endif
        case .error:
            #if DEBUG
            logger.error("\(rendered, privacy: .public)")
            #else
            logger.error("\(rendered, privacy: .private)")
            #endif
        case .critical:
            #if DEBUG
            logger.critical("\(rendered, privacy: .public)")
            #else
            logger.critical("\(rendered, privacy: .private)")
            #endif
        }
    }
}
