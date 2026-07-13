import CmuxNotifications

@MainActor
final class IncomingNotificationFocusingFake: IncomingNotificationFocusing {
    var outcome: IncomingNotificationFocusOutcome = .ignored
    private(set) var targets: [IncomingNotificationFocusTarget?] = []
    private(set) var desktopDeliveryFlags: [Bool] = []

    func focusIfNeeded(
        target: IncomingNotificationFocusTarget?,
        isDesktopDeliveryEnabled: Bool
    ) -> IncomingNotificationFocusOutcome {
        targets.append(target)
        desktopDeliveryFlags.append(isDesktopDeliveryEnabled)
        return outcome
    }
}
