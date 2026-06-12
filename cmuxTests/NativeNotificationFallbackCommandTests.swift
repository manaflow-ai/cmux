import Foundation
import Testing
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct NativeNotificationFallbackCommandTests {
    private struct CommandInvocation: Equatable {
        let title: String
        let subtitle: String
        let body: String
    }

    @Test
    func deniedNativeNotificationAuthorizationDoesNotRunCustomCommandFallback() {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        var didAttemptSchedule = false
        var commands: [CommandInvocation] = []
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(false)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            didAttemptSchedule = true
            completion(nil)
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Real title",
            subtitle: "",
            body: "Real message"
        )

        #expect(commands.isEmpty)
        #expect(!didAttemptSchedule)
    }

    @Test
    func failedNativeNotificationSchedulingDoesNotRunCustomCommandFallback() async {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        var commands: [CommandInvocation] = []
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(true)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            completion(NSError(domain: "cmuxTests.NotificationScheduling", code: 1))
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Real title",
            subtitle: "",
            body: "Real message"
        )
        await Task.yield()

        #expect(commands.isEmpty)
    }

    @Test
    func sharedNativeUnavailableFeedbackSuppressesCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = false
        effects.command = true
        var commands: [CommandInvocation] = []

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects,
            runCommand: false
        ) { title, subtitle, body in
            commands.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
        }

        #expect(commands.isEmpty)
    }

    @Test
    func sharedDesktopDisabledFeedbackAllowsCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = false
        effects.sound = false
        effects.command = true
        var commands: [CommandInvocation] = []

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects
        ) { title, subtitle, body in
            commands.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
        }

        #expect(commands == [
            CommandInvocation(title: "Real title", subtitle: "", body: "Real message"),
        ])
    }

    private func resetState(originalAppFocusOverride: Bool?) {
        let store = TerminalNotificationStore.shared
        store.replaceNotificationsForTesting([])
        store.resetNotificationDeliveryHandlerForTesting()
        store.resetNotificationAuthorizationHandlerForTesting()
        store.resetUserNotificationSchedulerForTesting()
        store.resetNotificationCommandRunnerForTesting()
        store.resetSuppressedNotificationFeedbackHandlerForTesting()
        AppFocusState.overrideIsFocused = originalAppFocusOverride
    }
}
