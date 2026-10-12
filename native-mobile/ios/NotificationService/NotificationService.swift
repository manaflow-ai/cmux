import UserNotifications

/// Renders cmux attention pushes: agent and workspace as the subtitle, the
/// prompt being answered quoted above the body, and, for a numbered menu,
/// a category with one button per choice.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let payload = PushPayload(userInfo: request.content.userInfo) else {
            contentHandler(request.content)
            return
        }
        self.content = content
        PushCategory.enrich(content, payload: payload)
        guard payload.kind == "question" || payload.kind == "permission", payload.options.count >= 2 else {
            contentHandler(content)
            return
        }
        let category = PushCategory.choices(payload.options)
        content.categoryIdentifier = category.identifier
        let box = HandlerBox(contentHandler, content)
        Task {
            await PushCategory.register(category)
            box.finish()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let content { contentHandler(content) }
    }
}

/// Carries the non-Sendable handler and content into the registration task.
private final class HandlerBox: @unchecked Sendable {
    let handler: (UNNotificationContent) -> Void
    let content: UNMutableNotificationContent
    init(_ handler: @escaping (UNNotificationContent) -> Void, _ content: UNMutableNotificationContent) {
        self.handler = handler
        self.content = content
    }
    func finish() { handler(content) }
}
