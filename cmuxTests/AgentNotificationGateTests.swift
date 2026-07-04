import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exhaustive decision-table coverage for the app-side agent notification gate
/// and the optional `c=<category>;p=<0|1>;a=<agent-id>` meta parser it consumes.
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
        #expect(a?.agentId == nil)

        let b = AgentNotificationMeta(meta: "c=needs-permission;p=0")
        #expect(b?.category == .needsPermission)
        #expect(b?.pending == false)
        #expect(b?.agentId == nil)

        let c = AgentNotificationMeta(meta: "c=idle-reminder;p=1")
        #expect(c?.category == .idleReminder)
        #expect(c?.pending == true)
        #expect(c?.agentId == nil)
    }

    @Test func metaParsesCategoryPendingAndAgent() {
        let meta = AgentNotificationMeta(meta: "c=turn-complete;p=1;a=claude")
        #expect(meta?.category == .turnComplete)
        #expect(meta?.pending == true)
        #expect(meta?.agentId == "claude")
    }

    @Test func metaParsesAgentOnlyAsOther() {
        let meta = AgentNotificationMeta(meta: "a=pi")
        #expect(meta?.category == .other)
        #expect(meta?.pending == false)
        #expect(meta?.agentId == "pi")
        #expect(agentNotificationShouldDeliver(
            category: meta?.category ?? .needsPermission,
            pending: meta?.pending ?? true,
            permissionEnabled: false,
            turnMode: .never,
            idleEnabled: false
        ) == true)
    }

    @Test func metaUnknownCategoryIsRejected() {
        // Only the three known category literals are wire-valid; anything else
        // (including "c=other") stays part of the legacy notification body.
        #expect(AgentNotificationMeta(meta: "c=bogus;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=other;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=note;p=1") == nil)
    }

    @Test func metaWithoutCategoryIsNil() {
        // A segment lacking `c=` or canonical `a=` is not our grammar; upstream never treats it as meta.
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
        // Only the CLI's exact serialization parses; reordered, duplicated, or
        // trailing fields stay part of the legacy body.
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;note") == nil)
        #expect(AgentNotificationMeta(meta: "p=1;c=turn-complete") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;c=turn-complete;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;a=claude") == nil)
        #expect(AgentNotificationMeta(meta: "a=claude;c=turn-complete;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;a=claude;extra=1") == nil)
    }

    @Test func metaRejectsInvalidAgentIds() {
        #expect(AgentNotificationMeta(meta: "a=") == nil)
        #expect(AgentNotificationMeta(meta: "a=UPPER") == nil)
        #expect(AgentNotificationMeta(meta: "a=has_underscore") == nil)
        #expect(AgentNotificationMeta(meta: "a=abcdefghijklmnopqrstuvwxyzabcdefg") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;a=UPPER") == nil)
    }
}
