import Foundation
import UserNotifications

/// The `cmux` block the Worker puts in every alert payload, plus the
/// notification categories and actions. Shared by the app and the
/// Notification Service Extension.
struct PushPayload: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        var key: String
        var label: String
    }

    var hostID: String
    var hostName: String?
    var eventID: String
    var kind: String
    var surface: Int?
    var workspace: String?
    var agent: String?
    var options: [Option]
    var quote: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let cmux = userInfo["cmux"] as? [String: Any],
              let host = cmux["host_id"] as? String, let event = cmux["event_id"] as? String else { return nil }
        hostID = host
        hostName = cmux["host_name"] as? String
        eventID = event
        kind = cmux["kind"] as? String ?? "notice"
        surface = (cmux["surface"] as? NSNumber)?.intValue
        workspace = cmux["workspace"] as? String
        agent = cmux["agent"] as? String
        options = (cmux["options"] as? [[String: Any]] ?? []).compactMap { o in
            guard let key = o["key"] as? String, let label = o["label"] as? String else { return nil }
            return Option(key: key, label: label)
        }
        quote = (cmux["quote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var agentDisplayName: String {
        guard let agent, !agent.isEmpty else { return String(localized: "Agent") }
        switch agent.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
}

enum PushCategory {
    static let question = "FEED_QUESTION"
    static let permission = "FEED_PERMISSION"
    static let done = "FEED_DONE"
    static let generic = "FEED_GENERIC"

    static let replyAction = "reply"
    static let allowAction = "allow"
    static let denyAction = "deny"
    static let optionPrefix = "option:"

    static func optionAction(_ key: String) -> String { optionPrefix + key }

    static var reply: UNTextInputNotificationAction {
        UNTextInputNotificationAction(
            identifier: replyAction, title: String(localized: "Reply"), options: [.authenticationRequired],
            icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Message the agent"))
    }

    /// Static categories, registered at launch.
    static func base() -> Set<UNNotificationCategory> {
        let allow = UNNotificationAction(identifier: allowAction, title: String(localized: "Allow"), options: [.authenticationRequired],
                                         icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: denyAction, title: String(localized: "Deny"), options: [.authenticationRequired, .destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        return [
            UNNotificationCategory(identifier: question, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: permission, actions: [allow, deny, reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: done, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: generic, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    /// A per-menu category: one button per choice plus Reply. Its id
    /// encodes the choices so identical menus share one category.
    static func choices(_ options: [PushPayload.Option]) -> UNNotificationCategory {
        let shown = Array(options.prefix(4))
        let signature = shown.map { "\($0.key)=\($0.label)" }.joined(separator: "|")
        var hasher = StableHash()
        hasher.combine(signature)
        let actions: [UNNotificationAction] = shown.map { option in
            let destructive = option.label.lowercased().hasPrefix("no")
            return UNNotificationAction(identifier: optionAction(option.key), title: "\(option.key). \(option.label)",
                                        options: destructive ? [.authenticationRequired, .destructive] : [.authenticationRequired])
        } + [reply]
        return UNNotificationCategory(identifier: "\(question).\(hasher.value)", actions: actions, intentIdentifiers: [], options: [])
    }

    /// Adds `category` to the registered set (keeps at most 24 menu categories).
    static func register(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        var current = await center.notificationCategories()
        if current.contains(where: { $0.identifier == category.identifier }) { return }
        let dynamic = current.filter { $0.identifier.hasPrefix("\(question).") }
        if dynamic.count >= 24, let drop = dynamic.first { current.remove(drop) }
        current.formUnion(base().filter { b in !current.contains { $0.identifier == b.identifier } })
        current.insert(category)
        center.setNotificationCategories(current)
    }

    /// The richer content the service extension shows: agent and workspace
    /// as the subtitle, and the prompt being answered quoted above the body.
    static func enrich(_ content: UNMutableNotificationContent, payload: PushPayload) {
        var subtitle = [payload.agentDisplayName]
        if let workspace = payload.workspace, !workspace.isEmpty { subtitle.append(workspace) }
        if let host = payload.hostName, !host.isEmpty { subtitle.append(host) }
        content.subtitle = subtitle.joined(separator: " · ")
        if let quote = payload.quote {
            let clipped = quote.count > 160 ? String(quote.prefix(159)) + "…" : quote
            content.body = "“\(clipped)”\n\(content.body)"
        }
        if let surface = payload.surface { content.targetContentIdentifier = "surface:\(payload.hostID):\(surface)" }
        if payload.kind == "question" || payload.kind == "permission" { content.relevanceScore = 1 }
    }
}

/// FNV-1a, stable across launches (Hasher is seeded per process).
struct StableHash {
    private(set) var value: UInt64 = 0xcbf29ce484222325
    mutating func combine(_ s: String) {
        for byte in s.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
    }
}
