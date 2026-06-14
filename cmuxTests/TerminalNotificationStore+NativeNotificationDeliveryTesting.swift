import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalNotificationStore {
    func configureNotificationAuthorizationHandlerForTesting(
        _ handler: @escaping (@escaping (Bool, NotificationAuthorizationState) -> Void) -> Void
    ) {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = handler
    }

    func resetNotificationAuthorizationHandlerForTesting() {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = nil
    }

    func configureUserNotificationSchedulerForTesting(
        _ scheduler: @escaping (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    ) {
        nativeNotificationDeliveryHooks.scheduler = scheduler
    }

    func resetUserNotificationSchedulerForTesting() {
        nativeNotificationDeliveryHooks.scheduler = NativeNotificationDeliveryHooks().scheduler
    }

    func configureNotificationCommandRunnerForTesting(
        _ runner: @escaping (String, String, String) -> Void
    ) {
        nativeNotificationDeliveryHooks.commandRunner = runner
    }

    func resetNotificationCommandRunnerForTesting() {
        nativeNotificationDeliveryHooks.commandRunner = NativeNotificationDeliveryHooks().commandRunner
    }
}
