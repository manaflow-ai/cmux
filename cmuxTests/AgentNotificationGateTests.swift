import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exhaustive decision-table coverage for the app-side agent notification gate
/// and the `c=<category>;p=<0|1>` meta parser it consumes.
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
        // Only the CLI's exact canonical serialization parses; reordered,
        // duplicated, or trailing fields stay part of the legacy body.
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;note") == nil)
        #expect(AgentNotificationMeta(meta: "p=1;c=turn-complete") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;c=turn-complete;p=1") == nil)
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=1;") == nil)
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
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=Claude") == nil)
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
        #expect(!AgentNotificationMeta.isValidAgentKindTag("Claude"))
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

    @Test func contextualMetaRejectsCategoryAlertMismatchAndMalformedAgent() {
        #expect(AgentNotificationMeta(meta: "c=turn-complete;p=0;a=claude;s=needsInput") == nil)
        #expect(AgentNotificationMeta(meta: "c=needs-permission;p=0;evil;s=needsInput") == nil)
        #expect(AgentNotificationMeta(meta: "c=other;p=0;a=claude;s=turnDone") == nil)
        #expect(
            AgentNotificationMeta(meta: "c=other;p=0;a=claude;s=errorStalled")?.soundContext
                == NotificationSoundOverrideContext(agentID: "claude", alertType: .errorStalled)
        )
    }
}
