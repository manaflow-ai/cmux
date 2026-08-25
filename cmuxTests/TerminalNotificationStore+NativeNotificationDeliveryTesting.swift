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
        configureNativeNotificationDeliveryHooksForTesting {
            $0.authorizationHandlerForTesting = handler
        }
    }

    func resetNotificationAuthorizationHandlerForTesting() {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.authorizationHandlerForTesting = nil
        }
    }

    func configureUserNotificationSchedulerForTesting(
        _ scheduler: @escaping NativeNotificationDeliveryHooks.Scheduler
    ) {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.scheduler = scheduler
        }
    }

    func resetUserNotificationSchedulerForTesting() {
        configureNativeNotificationDeliveryHooksForTesting {
            // nil routes scheduling back through the production
            // notification-center service.
            $0.scheduler = nil
        }
    }

    func configureUnavailableFeedbackPlayerForTesting(
        _ player: @escaping NativeNotificationDeliveryHooks.UnavailableFeedbackPlayer
    ) {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.unavailableFeedbackPlayer = player
        }
    }

    func resetUnavailableFeedbackPlayerForTesting() {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.unavailableFeedbackPlayer = NativeNotificationDeliveryHooks.defaultUnavailableFeedbackPlayer
        }
    }

    func configureNotificationCommandRunnerForTesting(
        _ runner: @escaping NativeNotificationDeliveryHooks.CommandRunner
    ) {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.commandRunner = runner
        }
    }

    func resetNotificationCommandRunnerForTesting() {
        configureNativeNotificationDeliveryHooksForTesting {
            $0.commandRunner = NativeNotificationDeliveryHooks.defaultCommandRunner
        }
    }
}
