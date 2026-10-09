# cmux-next iOS product and interaction research

This note captures the product decisions that guide the first vertical slices. It turns the requested inspirations into testable behaviors; it is not a visual copy of another app.

## Evidence and borrowed patterns

| Reference | Useful pattern for cmux-next | Constraint we keep |
| --- | --- | --- |
| Codex and Claude mobile surfaces | Put the agent's current question, permission, or result in one focused stream; make the next action obvious | The Feed owner remains authoritative and every answer is an idempotent intent |
| X / timeline feeds | A compact chronological stream with unread state, inline actions, deep links, and optimistic motion | Offline mutations are disabled; the confirmed mirror and intent overlay remain the source of truth |
| iMessage | Conversation-like grouping, reply context, delivery/read states, and a clear compose affordance | Agent events are typed requests and results, not an unbounded chat transcript |
| T3Code | Start a useful coding task from a small set of high-value choices and reveal advanced controls only when needed | Composer selection is capability-driven; model/effort options never bypass host policy |
| Termius | Saved hosts, explicit trust, SSH key handling, and a direct-connect path that works without a cloud account | Host keys and credentials stay in Keychain/Secure Enclave; direct addresses are pinned to the host identity |
| Duolingo / Goodnotes onboarding | Short progressive steps, one success moment, permission requests in context, and a visible resume point | Onboarding never hides recovery: pairing, SSH, and offline states have actionable exits |

These references establish interaction principles, not vendor dependencies or user-facing terminology.

## Product principles

1. **The next action is visible.** Feed cards put the question or permission beside its answer controls. Terminal and browser surfaces expose reconnect, path, and permission state without making users inspect logs.
2. **One action, one owner.** Every mutation has an idempotency key and a visible pending/committed/refused state. The UI never invents a second optimistic copy while disconnected.
3. **Progressive disclosure.** The first composer step asks for host, workspace, and prompt. Model, effort, attachments, and advanced transport controls appear only when supported by the selected host.
4. **Trust is explicit.** Pairing and SSH show the identity being trusted, its fingerprint, and how to revoke it. Direct Tailscale/WireGuard routes do not silently fall back to a cloud route.
5. **Realtime has a bounded shape.** Stream views render the newest confirmed revision, resync on gaps, and keep bounded buffers. A spinner is a state transition, not a synchronization mechanism.
6. **Recovery is a first-class screen state.** Every offline, expired, revoked, paused, or stale-host condition names the next safe action and preserves local drafts without silently dispatching them.
7. **Accessible by construction.** Cards, controls, terminal gestures, and onboarding steps have stable identifiers, Dynamic Type layouts, Reduce Motion behavior, VoiceOver actions, and keyboard alternatives before visual dogfood.

## Vertical slice acceptance

The first usable loop is: open the Feed, answer a permission, launch a task from the composer, see the workspace appear, attach to its terminal, and recover after a forced reconnect. It is accepted only when the same state is observable from the confirmed owner revision and the UI explains every refusal.

The second loop adds a saved SSH host and a direct address. It must show host-key trust before the first attach, render a discovered session from the validated catalog, and refuse a stale or changed identity without selecting another target.

The carrier bakeoff measures these loops over direct, WebRTC, and WireGuard-over-WebRTC paths with the same feature protocol. UX behavior must not depend on which carrier wins.

## Research follow-ups

- Run five internal task-based sessions covering Feed answer, first pairing, composer dispatch, SSH trust, and reconnect recovery.
- Capture time-to-first-success, wrong-route attempts, refusal comprehension, and VoiceOver completion; attach findings to D3 rather than changing protocol ownership from anecdotal feedback.
- Revisit the Feed card density and onboarding step count after the first tagged pair; keep the wire contracts stable while changing presentation.
