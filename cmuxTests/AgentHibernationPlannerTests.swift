import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Deterministic tests for the hibernate-selection logic itself
/// (`AgentHibernationPlanner.selectedPanelKeys`). This is the step that decides
/// which idle, restorable, off-screen agents get hibernated once the live count
/// exceeds `maxLiveTerminals`. The notification-lifecycle fix elsewhere in this
/// change exists so that a finished agent reaches `.idle` here (rather than being
/// clobbered to `.needsInput`); this suite pins that an `.idle` agent is eligible
/// and a `.needsInput` one never is, plus the protection / idle-window / cap rules.
@Suite("AgentHibernationPlanner")
struct AgentHibernationPlannerTests {
    private let now: TimeInterval = 1_000_000

    private func key() -> AgentHibernationPanelKey {
        AgentHibernationPanelKey(workspaceId: UUID(), panelId: UUID())
    }

    private func input(
        _ lifecycle: AgentHibernationLifecycleState,
        idleFor: TimeInterval,
        isLive: Bool = true,
        isProtected: Bool = false,
        unconfirmedInput: Bool = false,
        hasRestorableAgent: Bool = true
    ) -> AgentHibernationPlannerInput {
        AgentHibernationPlannerInput(
            key: key(),
            hasRestorableAgent: hasRestorableAgent,
            isLive: isLive,
            isProtected: isProtected,
            lifecycle: lifecycle,
            hasUnconfirmedTerminalInput: unconfirmedInput,
            lastActivityAt: now - idleFor
        )
    }

    private func settings(maxLive: Int, idleSeconds: TimeInterval = 5) -> AgentHibernationSettings.Values {
        AgentHibernationSettings.Values(
            enabled: true,
            idleSeconds: idleSeconds,
            maxLiveTerminals: maxLive,
            confirmationSeconds: 60
        )
    }

    @Test("Selects the excess of idle restorable agents, oldest-activity first")
    func selectsIdleExcessOldestFirst() {
        let oldest = input(.idle, idleFor: 100)
        let middle = input(.idle, idleFor: 50)
        let newest = input(.idle, idleFor: 10)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [newest, middle, oldest],
            settings: settings(maxLive: 1),
            now: now
        )
        // 3 live restorable, cap 1 -> hibernate 2; the most-recently-active stays live.
        #expect(selected == Set([oldest.key, middle.key]))
        #expect(!selected.contains(newest.key))
    }

    @Test("A needs-input agent is never hibernated, even with excess")
    func needsInputNeverHibernates() {
        // The payoff of the notification-clobber fix: an agent that finished its turn
        // is `.idle` (eligible); an agent genuinely waiting on a prompt is `.needsInput`
        // (never eligible), so it cannot be hibernated out from under the user.
        let blocking = input(.needsInput, idleFor: 100)
        let idle = input(.idle, idleFor: 100)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [blocking, idle],
            settings: settings(maxLive: 1),
            now: now
        )
        #expect(selected == Set([idle.key]))
        #expect(!selected.contains(blocking.key))
    }

    @Test("running and unknown lifecycles are never hibernated")
    func nonIdleLifecyclesNeverHibernate() {
        for lifecycle: AgentHibernationLifecycleState in [.running, .unknown, .needsInput] {
            let busy = input(lifecycle, idleFor: 100)
            let idle = input(.idle, idleFor: 100)
            let selected = AgentHibernationPlanner.selectedPanelKeys(
                inputs: [busy, idle],
                settings: settings(maxLive: 1),
                now: now
            )
            #expect(!selected.contains(busy.key), "Expected \(lifecycle) to be ineligible")
        }
    }

    @Test("An idle agent within the idle window is not yet hibernated")
    func respectsIdleWindow() {
        let justIdle = input(.idle, idleFor: 2) // < idleSeconds (5)
        let longIdle = input(.idle, idleFor: 100)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [justIdle, longIdle],
            settings: settings(maxLive: 1, idleSeconds: 5),
            now: now
        )
        #expect(selected == Set([longIdle.key]))
        #expect(!selected.contains(justIdle.key))
    }

    @Test("Protected and unconfirmed-input agents are excluded")
    func protectedAndUnconfirmedExcluded() {
        let protectedPanel = input(.idle, idleFor: 100, isProtected: true)
        let unconfirmed = input(.idle, idleFor: 100, unconfirmedInput: true)
        let plain = input(.idle, idleFor: 100)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [protectedPanel, unconfirmed, plain],
            settings: settings(maxLive: 1),
            now: now
        )
        // 3 live restorable, cap 1 -> excess 2, but only `plain` is eligible.
        #expect(selected == Set([plain.key]))
    }

    @Test("No hibernation when live restorable count is within the cap")
    func noExcessNoHibernation() {
        let a = input(.idle, idleFor: 100)
        let b = input(.idle, idleFor: 100)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [a, b],
            settings: settings(maxLive: 2),
            now: now
        )
        #expect(selected.isEmpty)
    }

    @Test("Non-live and non-restorable agents do not count toward the cap or get hibernated")
    func nonLiveNonRestorableIgnored() {
        // Only one live restorable idle agent; a dead one and a non-restorable one are
        // ignored, so with cap 1 there is no excess.
        let live = input(.idle, idleFor: 100)
        let dead = input(.idle, idleFor: 100, isLive: false)
        let nonRestorable = input(.idle, idleFor: 100, hasRestorableAgent: false)
        let selected = AgentHibernationPlanner.selectedPanelKeys(
            inputs: [live, dead, nonRestorable],
            settings: settings(maxLive: 1),
            now: now
        )
        #expect(selected.isEmpty)
    }

    @Test("Disabled settings hibernate nothing")
    func disabledHibernatesNothing() {
        let a = input(.idle, idleFor: 100)
        let b = input(.idle, idleFor: 100)
        let disabled = AgentHibernationSettings.Values(
            enabled: false, idleSeconds: 5, maxLiveTerminals: 1, confirmationSeconds: 60
        )
        let selected = AgentHibernationPlanner.selectedPanelKeys(inputs: [a, b], settings: disabled, now: now)
        #expect(selected.isEmpty)
    }

    @Test("Every supported coding-agent type can drive the hibernation lifecycle")
    func allAgentTypesAreLifecycleStatusKeys() {
        // The hibernation lifecycle is keyed per agent; an agent missing from the
        // allow-list could never report idle/needs-input and so could never hibernate.
        // Pin the full roster so adding an agent without wiring its lifecycle key fails.
        let expected: Set<String> = [
            "amp", "antigravity", "claude_code", "codebuddy", "codex", "copilot",
            "cursor", "factory", "gemini", "grok", "hermes-agent", "kiro",
            "opencode", "pi", "qoder", "rovodev",
        ]
        for key in expected {
            #expect(
                AgentHibernationLifecycleStatusKeys.isAllowed(key),
                "Agent lifecycle key \(key) must be allowed so it can hibernate"
            )
        }
    }
}
