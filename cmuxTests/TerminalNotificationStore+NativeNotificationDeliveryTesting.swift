import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalNotificationStore {
    func configureNotificationAuthorizationHandlerForTesting(
        _ handler: @escaping NativeNotificationDeliveryHooks.AuthorizationHandler
    ) {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = handler
    }

    func resetNotificationAuthorizationHandlerForTesting() {
        nativeNotificationDeliveryHooks.authorizationHandlerForTesting = nil
    }

    func configureUserNotificationSchedulerForTesting(
        _ scheduler: @escaping NativeNotificationDeliveryHooks.Scheduler
    ) {
        nativeNotificationDeliveryHooks.scheduler = scheduler
    }

    func resetUserNotificationSchedulerForTesting() {
        nativeNotificationDeliveryHooks.scheduler = NativeNotificationDeliveryHooks().scheduler
    }

    func configureNotificationCommandRunnerForTesting(
        _ runner: @escaping NativeNotificationDeliveryHooks.CommandRunner
    ) {
        nativeNotificationDeliveryHooks.commandRunner = runner
    }

    func resetNotificationCommandRunnerForTesting() {
        nativeNotificationDeliveryHooks.commandRunner = NativeNotificationDeliveryHooks().commandRunner
    }
}
