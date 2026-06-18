import Foundation
import os
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
    private struct CommandInvocation: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String
    }

    private final class CommandInvocationRecorder: Sendable {
        private let invocationsLock = OSAllocatedUnfairLock(initialState: [CommandInvocation]())

        var invocations: [CommandInvocation] {
            invocationsLock.withLock { $0 }
        }

        func append(title: String, subtitle: String, body: String) {
            invocationsLock.withLock {
                $0.append(CommandInvocation(title: title, subtitle: subtitle, body: body))
            }
        }
    }

    private final class BoolRecorder: Sendable {
        private let valueLock = OSAllocatedUnfairLock(initialState: false)

        var value: Bool {
            valueLock.withLock { $0 }
        }

        func setTrue() {
            valueLock.withLock { $0 = true }
        }
    }

    @Test
    func deniedNativeNotificationAuthorizationDoesNotRunCustomCommandFallback() {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        let didAttemptSchedule = BoolRecorder()
        let commands = CommandInvocationRecorder()
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(false, .denied)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            didAttemptSchedule.setTrue()
            completion(nil)
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Real title",
            subtitle: "",
            body: "Real message"
        )

        #expect(commands.invocations.isEmpty)
        #expect(!didAttemptSchedule.value)
    }

    @Test
    func failedNativeNotificationSchedulingDoesNotRunCustomCommandFallback() async {
        let store = TerminalNotificationStore.shared
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        resetState(originalAppFocusOverride: false)
        defer { resetState(originalAppFocusOverride: originalAppFocusOverride) }

        let commands = CommandInvocationRecorder()
        store.configureNotificationAuthorizationHandlerForTesting { completion in
            completion(true, .authorized)
        }
        store.configureUserNotificationSchedulerForTesting { _, completion in
            completion(NSError(domain: "cmuxTests.NotificationScheduling", code: 1))
        }
        store.configureNotificationCommandRunnerForTesting { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        store.addNotification(
            tabId: UUID(),
            surfaceId: nil,
            title: "Real title",
            subtitle: "",
            body: "Real message"
        )
        await Task.yield()

        #expect(commands.invocations.isEmpty)
    }

    @Test
    func sharedNativeUnavailableFeedbackSuppressesCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = false
        effects.command = true
        let commands = CommandInvocationRecorder()

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects,
            runCommand: false
        ) { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        #expect(commands.invocations.isEmpty)
    }

    @Test
    func sharedDesktopDisabledFeedbackAllowsCommandRunner() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = false
        effects.sound = false
        effects.command = true
        let commands = CommandInvocationRecorder()

        NativeNotificationDeliveryHooks.runLocalFeedback(
            title: "Real title",
            subtitle: "",
            body: "Real message",
            effects: effects
        ) { title, subtitle, body in
            commands.append(title: title, subtitle: subtitle, body: body)
        }

        #expect(commands.invocations == [
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
