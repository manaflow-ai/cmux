import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exhaustive decision-table coverage for the app-side agent notification gate
/// and the category/approval meta parser it consumes.
@Suite struct AgentNotificationGateTests {
    @Test func needsPermissionFollowsToggleAndIgnoresPending() {
        for pending in [false, true] {
            #expect(agentNotificationShouldDeliver(
                category: .needsPermission, pending: pending,
                permissionEnabled: true, turnMode: .whenIdle, idleEnabled: true) == true)
            #expect(agentNotificationShouldDeliver(
                category: .needsPermission, pending: pending,
                permissionEnabled: false, turnMode: .whenIdle, idleEnabled: true) == false)
        }
    }

    @Test func turnCompleteWhenIdleSuppressesWhilePending() {
        #expect(agentNotificationShouldDeliver(
            category: .turnComplete, pending: false,
            permissionEnabled: true, turnMode: .whenIdle, idleEnabled: true) == true)
        #expect(agentNotificationShouldDeliver(
            category: .turnComplete, pending: true,
            permissionEnabled: true, turnMode: .whenIdle, idleEnabled: true) == false)
    }

    @Test func turnCompleteAlwaysAndNeverIgnorePending() {
        for pending in [false, true] {
            #expect(agentNotificationShouldDeliver(
                category: .turnComplete, pending: pending,
                permissionEnabled: true, turnMode: .always, idleEnabled: true) == true)
            #expect(agentNotificationShouldDeliver(
                category: .turnComplete, pending: pending,
                permissionEnabled: true, turnMode: .never, idleEnabled: true) == false)
        }
    }

    @Test func idleReminderRequiresToggleAndNotPending() {
        #expect(agentNotificationShouldDeliver(
            category: .idleReminder, pending: false,
            permissionEnabled: true, turnMode: .whenIdle, idleEnabled: true) == true)
        #expect(agentNotificationShouldDeliver(
            category: .idleReminder, pending: true,
            permissionEnabled: true, turnMode: .whenIdle, idleEnabled: true) == false)
        #expect(agentNotificationShouldDeliver(
            category: .idleReminder, pending: false,
            permissionEnabled: true, turnMode: .whenIdle, idleEnabled: false) == false)
    }

    @Test func otherCategoryAlwaysDelivers() {
        for pending in [false, true] {
            #expect(agentNotificationShouldDeliver(
                category: .other, pending: pending,
                permissionEnabled: false, turnMode: .never, idleEnabled: false) == true)
        }
    }

    @Test func metaParsesCategoryAndPending() {
        let a = AgentNotificationMeta(meta: "c=turn-complete;p=1")
        #expect(a?.category == .turnComplete)
        #expect(a?.pending == true)

        let b = AgentNotificationMeta(meta: "c=needs-permission;p=0")
        #expect(b?.category == .needsPermission)
        #expect(b?.pending == false)

        let c = AgentNotificationMeta(meta: "c=idle-reminder;p=1")
        #expect(c?.category == .idleReminder)
        #expect(c?.pending == true)
    }

    @Test func metaParsesCanonicalApprovalCorrelation() {
        let approvalID = "111111111111111111111111.aaaaaaaaaaaaaaaaaaaaaaaa"
        let meta = AgentNotificationMeta(
            meta: "c=needs-permission;p=0;a=\(approvalID)"
        )

        #expect(meta?.category == .needsPermission)
        #expect(meta?.pending == false)
        #expect(meta?.approvalID?.rawValue == approvalID)
        #expect(meta?.approvalID?.scope.rawValue == "111111111111111111111111")
    }

    @Test func metaUnknownCategoryIsRejected() {
        // Only the three known category literals are wire-valid; anything else
        // (including "c=other") stays part of the legacy notification body.
        #expect(AgentNotificationMeta(meta: "c=bogus;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=other;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=note;p=1") == nil)
    }

    @Test func metaWithoutCategoryIsNil() {
        // A segment lacking `c=` is not our grammar; upstream never treats it as meta.
        #expect(AgentNotificationMeta(meta: "p=1") == nil)
    }

    @Test func metaRequiresValidPendingFlag() {
        // A legacy body tail that merely starts with "c=" must not become a
        // gating directive: the FULL grammar requires p=0|1.
        #expect(AgentNotificationMeta(meta: "c=turn-complete") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=2") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=") == nil)
        #expect(AgentNotificationMeta(meta: "c=value") == nil)
    }

    @Test func metaRequiresExactCanonicalForm() {
        // Only the CLI's exact canonical serialization (including the
        // approval extension) parses; reordered, duplicated, or trailing fields
        // stay part of the legacy body.
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;note") == nil)
        #expect(AgentNotificationMeta(meta: "p=1;c=turn-complete") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;c=turn-complete;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;a=111111111111111111111111.aaaaaaaaaaaaaaaaaaaaaaaa") == nil)
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;a=not-a-token") == nil)
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;a=111111111111111111111111.AAAAAAAAAAAAAAAAAAAAAAAA") == nil)
    }

    @Test func legacyTwoFieldMetaParsesWithoutAgentContext() {
        // Pre-extension senders emit only `c=;p=`: identical parse to before,
        // with no agent context attached.
        let parsed = AgentNotificationMeta(meta: "c=turn-complete;p=0")
        #expect(parsed?.category == .turnComplete)
        #expect(parsed?.pending == false)
        #expect(parsed?.agentKind == nil)
        #expect(parsed?.isSubagent == nil)
    }

    @Test func metaParsesAgentKindAndSubagentFlag() {
        let full = AgentNotificationMeta(meta: "c=turn-complete;p=0;a=claude;n=1")
        #expect(full?.category == .turnComplete)
        #expect(full?.pending == false)
        #expect(full?.agentKind == "claude")
        #expect(full?.isSubagent == true)

        let kindOnly = AgentNotificationMeta(meta: "c=needs-permission;p=1;a=hermes-agent")
        #expect(kindOnly?.agentKind == "hermes-agent")
        #expect(kindOnly?.isSubagent == nil)

        let flagOnly = AgentNotificationMeta(meta: "c=idle-reminder;p=0;n=0")
        #expect(flagOnly?.agentKind == nil)
        #expect(flagOnly?.isSubagent == false)
    }

    @Test func metaParsesAndValidatesCorrelationKey() {
        let key = "11111111-1111-1111-1111-111111111111"
        let parsed = AgentNotificationMeta(
            meta: "c=needs-permission;p=0;a=cursor;n=0;k=\(key)"
        )
        #expect(parsed?.correlationKey == key)
        #expect(
            AgentNotificationMeta(meta: "c=needs-permission;p=0;k=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")?.correlationKey
                == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )
        #expect(AgentNotificationMeta.isValidCorrelationKey(key))
        #expect(!AgentNotificationMeta.isValidCorrelationKey("not-a-uuid"))
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;k=not-a-uuid") == nil)
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;k=\(key);n=0") == nil)
    }

    @Test func metaRejectsMalformedAgentFields() {
        // The extended grammar is just as strict as the legacy one: invalid
        // slugs, bad flags, reordered or duplicated fields all fold the whole
        // segment back into the legacy notification body.
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=Claude")?.agentKind == "Claude")
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=cl aude") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;n=2") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;n=") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;n=1;a=claude") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=claude;a=codex") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=claude;n=1;x=1") == nil)
    }

    @Test func agentKindTagValidationMatchesSlugGrammar() {
        #expect(AgentNotificationMeta.isValidAgentKindTag("claude"))
        #expect(AgentNotificationMeta.isValidAgentKindTag("hermes-agent"))
        #expect(AgentNotificationMeta.isValidAgentKindTag("agent_2.beta"))
        #expect(!AgentNotificationMeta.isValidAgentKindTag(""))
        #expect(AgentNotificationMeta.isValidAgentKindTag("Claude"))
        #expect(!AgentNotificationMeta.isValidAgentKindTag("a|b"))
        #expect(!AgentNotificationMeta.isValidAgentKindTag("a;b"))
        #expect(!AgentNotificationMeta.isValidAgentKindTag(String(repeating: "a", count: 65)))
    }

    @Test func contextualMetaRoundTripsAgentAndAlertType() throws {
        let meta = try #require(
            AgentHookNotifyCategory.needsPermission.metaSegment(
                pending: false,
                agentID: " hermes-agent ",
                alertType: .needsInput
            )
        )
        let parsed = try #require(AgentNotificationMeta(meta: meta))
        #expect(parsed.category == .needsPermission)
        #expect(parsed.pending == false)
        #expect(parsed.soundContext == NotificationSoundOverrideContext(
            agentID: "hermes-agent",
            alertType: .needsInput
        ))
    }

    @Test func contextualMetaRetainsSubagentFlag() throws {
        let meta = try #require(
            AgentHookNotifyCategory.turnComplete.metaSegment(
                pending: false,
                agentID: "claude",
                isSubagent: true
            )
        )
        let parsed = try #require(AgentNotificationMeta(meta: meta))
        #expect(parsed.agentKind == "claude")
        #expect(parsed.isSubagent == true)
        #expect(parsed.soundContext?.alertType == .turnDone)
    }

    @Test func contextualMetaRejectsCategoryAlertMismatchAndMalformedAgent() throws {
        let generatedErrorMeta = try #require(
            AgentHookNotifyCategory.other.metaSegment(
                pending: false,
                agentID: "claude",
                alertType: .errorStalled
            )
        )
        let generatedError = try #require(AgentNotificationMeta(meta: generatedErrorMeta))
        #expect(generatedError.category == .other)
        #expect(generatedError.soundContext == NotificationSoundOverrideContext(
            agentID: "claude",
            alertType: .errorStalled
        ))
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=claude;s=needsInput") == nil)
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;evil;s=needsInput") == nil)
        #expect(AgentNotificationMeta(meta: "c=other;p=0;a=claude;s=turnDone") == nil)
        #expect(
            AgentNotificationMeta(meta: "c=other;p=0;a=claude;s=errorStalled")?.soundContext
                == NotificationSoundOverrideContext(agentID: "claude", alertType: .errorStalled)
        )
    }
}

@MainActor
@Suite struct AgentApprovalNotificationCoordinatorTests {
    private static let workspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let surfaceID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
    private static let firstApprovalID = AgentApprovalCorrelationID(
        rawValue: "111111111111111111111111.aaaaaaaaaaaaaaaaaaaaaaaa"
    )!
    private static let secondApprovalID = AgentApprovalCorrelationID(
        rawValue: "111111111111111111111111.bbbbbbbbbbbbbbbbbbbbbbbb"
    )!

    @Test func autoResolvedApprovalProducesNoNotification() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "shell needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        fixture.scheduler.runAll()

        #expect(fixture.deliveries.isEmpty)
        #expect(fixture.clears.isEmpty)
    }

    @Test func genuinelyBlockingApprovalNotifiesAfterSettleWindow() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "shell needs approval",
            approvalID: Self.firstApprovalID
        )
        #expect(fixture.deliveries.isEmpty)

        fixture.scheduler.runAll()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.deliveries.first?.body == "shell needs approval")
    }

    @Test func deliveredApprovalClearsWhenItResolves() throws {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "shell needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.scheduler.runAll()
        let delivery = try #require(fixture.deliveries.first)

        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )

        #expect(fixture.clears.count == 1)
        #expect(fixture.clears.first?.surfaceID == Self.surfaceID)
        #expect(fixture.clears.first?.correlationKey == delivery.correlationKey)
    }

    @Test func pendingApprovalsInOnePaneCoalesceIntoOneNotification() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "first tool needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "second tool needs approval",
            approvalID: Self.secondApprovalID
        )
        fixture.scheduler.runAll()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.deliveries.first?.body == "second tool needs approval")

        // The older request may resolve after the shared banner is already
        // visible. Its completion must not clear the still-pending second one.
        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        #expect(fixture.deliveries.count == 1)
        #expect(fixture.clears.isEmpty)
    }

    @Test func turnResolutionCancelsDeniedApprovalBeforeDelivery() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "shell needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalScope: Self.firstApprovalID.scope
        )
        fixture.scheduler.runAll()

        #expect(fixture.deliveries.isEmpty)
    }

    @Test func reorderedOldResolutionDoesNotCancelNewApproval() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "new tool needs approval",
            approvalID: Self.secondApprovalID
        )
        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "old tool needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "duplicate old tool needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.scheduler.runAll()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.deliveries.first?.body == "new tool needs approval")
    }

    @Test func duplicateApprovalSignalsClearWithOneCompletion() {
        let fixture = Fixture()

        for body in ["first identical call", "second identical call"] {
            fixture.coordinator.stage(
                workspaceID: Self.workspaceID,
                surfaceID: Self.surfaceID,
                title: "Codex",
                subtitle: "Permission",
                body: body,
                approvalID: Self.firstApprovalID
            )
        }
        fixture.scheduler.runAll()
        #expect(fixture.deliveries.count == 1)

        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        #expect(fixture.clears.count == 1)

        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        #expect(fixture.clears.count == 1)
    }

    @Test func laterRequestsDoNotPostponeAnOlderBlockingApproval() {
        let fixture = Fixture()

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "older blocking approval",
            approvalID: Self.firstApprovalID
        )
        fixture.scheduler.advance(by: 0.09)
        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "new arrival",
            approvalID: Self.secondApprovalID
        )

        fixture.scheduler.advance(by: 0.02)

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.deliveries.first?.body == "older blocking approval")
    }

    @Test func resolutionAppliedBeforeQueuedDeadlinePreventsDelivery() {
        let fixture = Fixture(defersScheduledActions: true)

        fixture.coordinator.stage(
            workspaceID: Self.workspaceID,
            surfaceID: Self.surfaceID,
            title: "Codex",
            subtitle: "Permission",
            body: "shell needs approval",
            approvalID: Self.firstApprovalID
        )
        fixture.scheduler.runAll()

        fixture.coordinator.resolve(
            surfaceID: Self.surfaceID,
            approvalID: Self.firstApprovalID
        )
        fixture.scheduledActionDispatcher.runAll()

        #expect(fixture.deliveries.isEmpty)
        #expect(fixture.clears.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let scheduler = ManualScheduler()
        let scheduledActionDispatcher = ManualActionDispatcher()
        let defersScheduledActions: Bool
        var deliveries: [AgentApprovalNotificationCoordinator.Delivery] = []
        var clears: [AgentApprovalNotificationCoordinator.Clear] = []

        init(defersScheduledActions: Bool = false) {
            self.defersScheduledActions = defersScheduledActions
        }

        lazy var coordinator = AgentApprovalNotificationCoordinator(
            settleDelay: 0.1,
            now: { [scheduler] in scheduler.now },
            schedule: scheduler.schedule(delay:action:),
            dispatchScheduledAction: { [weak self] action in
                guard let self else { return }
                if defersScheduledActions {
                    scheduledActionDispatcher.enqueue(action)
                } else {
                    action()
                }
            },
            deliver: { [weak self] in self?.deliveries.append($0) },
            clear: { [weak self] in self?.clears.append($0) }
        )
    }

    @MainActor
    private final class ManualActionDispatcher {
        private var actions: [AgentApprovalNotificationCoordinator.Action] = []

        func enqueue(_ action: @escaping AgentApprovalNotificationCoordinator.Action) {
            actions.append(action)
        }

        func runAll() {
            let pending = actions
            actions.removeAll()
            for action in pending {
                action()
            }
        }
    }

    @MainActor
    private final class ManualScheduler {
        @MainActor
        private final class Entry {
            var isCancelled = false
            let deadline: TimeInterval
            let action: AgentApprovalNotificationCoordinator.Action

            init(
                deadline: TimeInterval,
                action: @escaping AgentApprovalNotificationCoordinator.Action
            ) {
                self.deadline = deadline
                self.action = action
            }
        }

        private(set) var now: TimeInterval = 0
        private var entries: [Entry] = []

        func schedule(
            delay: TimeInterval,
            action: @escaping AgentApprovalNotificationCoordinator.Action
        ) -> AgentApprovalNotificationCoordinator.Cancellation {
            let entry = Entry(deadline: now + delay, action: action)
            entries.append(entry)
            return { entry.isCancelled = true }
        }

        func runAll() {
            run(until: .infinity)
        }

        func advance(by interval: TimeInterval) {
            run(until: now + interval)
        }

        private func run(until deadline: TimeInterval) {
            while let index = entries.indices.min(by: {
                entries[$0].deadline < entries[$1].deadline
            }) {
                let entry = entries[index]
                if entry.isCancelled {
                    entries.remove(at: index)
                    continue
                }
                guard entry.deadline <= deadline + 0.000_001 else { break }
                entries.remove(at: index)
                now = max(now, entry.deadline)
                entry.action()
            }
            if deadline.isFinite {
                now = max(now, deadline)
            }
        }
    }
}
