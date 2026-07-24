import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exhaustive decision-table coverage for the app-side agent notification gate
/// and the legacy/ordered agent notification metadata parser it consumes.
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

    @Test func metaAcceptsCanonicalAgentEventOrderingFields() {
        let ordered = AgentNotificationMeta(
            meta: "c=needs-permission;p=0;k=claude_code;t=1700000200.000000"
        )

        #expect(ordered?.category == .needsPermission)
        #expect(ordered?.pending == false)
        #expect(ordered?.agentStatusKey == "claude_code")
        #expect(ordered?.agentEventTime == 1_700_000_200)
    }

    @Test(arguments: ["1", "1e300", "4102444801"])
    func metaRejectsOutOfRangeAgentEventTimes(rawEventTime: String) {
        #expect(
            AgentNotificationMeta(
                meta: "c=needs-permission;p=0;k=claude_code;t=\(rawEventTime)"
            ) == nil
        )
    }

    @Test func metaRejectsPlausibleEpochThatIsFarInTheFuture() {
        #expect(
            AgentNotificationMeta(
                meta: "c=needs-permission;p=0;k=claude_code;t=4102444800"
            ) == nil
        )
    }

    @Test func metaUnknownCategoryIsRejected() {
        // Unknown category literals stay part of the legacy notification body;
        // the ungated `other` category is valid only in the ordered four-field form.
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
        // Only the CLI's exact two- or four-field serialization parses; reordered,
        // duplicated, or otherwise trailing fields stay part of the legacy body.
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;note") == nil)
        #expect(AgentNotificationMeta(meta: "p=1;c=turn-complete") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;c=turn-complete;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;") == nil)
    }
}
