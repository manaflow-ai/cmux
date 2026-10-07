# cmux-next iOS execution snapshot

Updated 2026-10-07. This is the working handoff for the next implementation wave. The
authoritative lane contracts remain in [PLAN.md](PLAN.md); this file records what is
actually ready to run from the current `feat-cmux-next-ios` head.

## Product loop

Every slice follows the same loop:

1. **Research:** record the user journey, the platform pattern being followed, the
   state owner, and the failure states before changing code.
2. **Contract:** define the protocol or feature seam and its mock behavior. A feature
   cannot depend directly on a carrier.
3. **Implementation:** ship the smallest vertical behavior through the seam, with a
   deterministic test for its state transitions and idempotency/reconnect behavior.
4. **Verification:** run focused package tests, static guards, then the affected tagged
   iOS/Mac pair. Record device evidence or the exact external blocker.
5. **Handoff:** update the lane note and D3 parity row before starting the next dependent
   slice.

The realtime invariant applies at every step: event driven delivery, bounded buffers,
ordered revisions, gap-triggered snapshots, reconnect resume, and one UI commit per
display frame. Offline state is a read-only mirror plus a local draft; mutations do not
silently queue.

## Current evidence and selected work

The refreshed D3 matrix at HEAD `d0678348d5` reports 84 of 98 parity rows done, with one
implementation gap (the remaining tmux workspace parity), five seam-only rows, four mocked
platform rows, and four intentional drops. B1 now rate-limits TURN and pending-snapshot repair
traffic by authenticated identity. C14's credentialed generic SOCKS route is wired to `WebRoute`,
and C9 has a bounded tmux control-mode hydration path for safe single-pane attachment; carrier,
device, multi-pane/history, lifecycle, and other explicitly mocked or seam-only evidence remain
open.
The existing A0/A1/A2/A3 and B1-B6 contracts are present, and the V1 WebRTC, V2
WebRTC-over-WireGuard, and V3 direct-address implementations remain separate behind `CmuxLink`.

The active wave is intentionally independent:

| Workstream | Depends on | First deliverable | Verification gate |
| --- | --- | --- | --- |
| Product/design research and scope reconciliation | current PLAN + D3 evidence | research note with user journeys, invariants, and ranked gaps | every selected gap has an acceptance row and owner |
| C14 browser parity | A0, A3, B5 seams | landed browser session, simulator stream, direct-host route, local port-forward, and credentialed generic SOCKS route | tagged WKWebView/SSH/direct-host and simulator verification |
| C9 SSH workspace parity | A1, A2, existing SSH host seam | landed deterministic tmux/screen/cmux-tui discovery, epoch-checked tmux control attach, and safe hydration for a single-pane window | tagged SSH verification; multi-pane/history/parser-state parity and target lifecycle remain |
| Integration and verification | completed slices | merged docs/code plus updated D3 rows | focused tests, static guards, tagged pair/device evidence |

## Completed in this wave

- `e2cb1ef9da` adds the research, J1–J8 journeys, current-head scope table, invariants,
  prioritized risks, and release acceptance. It corrects the original D3 count's historical
  status instead of treating it as a current completion claim.
- `864c3eddbf` routes saved direct-address hosts through the in-app browser tunnel and makes
  loopback URL policy consistent for `*.localhost` subframes. The focused address/navigation
  tests and static checks pass.
- `e3983cd23f` and `b83b98b583` preserve the exact validated cmux-tui socket discovered over
  SSH and attach with `attach --socket`, with malformed-path, runtime-directory, replacement,
  and stale-session regressions. Syntax and scoped convention checks pass.
- `8240bc92e2` bounds `CmuxLink` channels, pending sessions, incoming channels and media tracks;
  overflow refuses or closes the resource, and focused tests cover the local channel cap and stalled
  incoming resource queues. Full package execution remains a fleet/build-host gate.
- `8017210242` adds identity-keyed B1 limits for TURN credential mints and pending snapshot forwards;
  the backend's focused Vitest suite (26 tests) and TypeScript typecheck pass.
- `0a9575efc3` adds bounded, epoch-checked tmux control-mode discovery, snapshot hydration and
  live pane output; native tests and live SSH verification remain a build-host/device gate.
- `d0678348d5` wires a credentialed generic SOCKS route through `WebRoute`; syntax and static checks
  pass, while native package tests, WKWebView and live reconnect verification remain pending.

The dedicated build host was unavailable during this wave (`cmux-lawrence-2` did not resolve),
so native package tests, tagged pair installs, visual evidence, and live SSH/browser paths remain
explicitly unverified. Static checks and focused syntax/tests for the follow-ups pass. The next
action is to rerun the same focused tests and D3 journeys when a fleet/build slot is available;
no local iOS build is substituted.

## Dependency graph for this wave

```mermaid
graph TD
  R[Research and scope note] --> C14[C14 browser acceptance]
  R --> C9[C9 SSH workspace acceptance]
  A0[A0 mobile wire] --> C14
  A3[A3 CmuxLink] --> C14
  B5[B5 Mac host adapters] --> C14
  A1[A1 shell and seams] --> C9
  A2[A2 Ghostty renderer] --> C9
  C14 --> V[Focused tests and static guards]
  C9 --> V
  V --> P[Tagged iOS/Mac pair verification]
  B2[B2 WebRTC] --> P
  B3[B3 WebRTC + WireGuard] --> P
  B4[B4 direct address] --> P
  P --> D3[D3 parity and bakeoff update]
```

The critical path for a usable terminal is still `A0/A3 -> B5 -> C1 -> D1`; the
selected work closes parity around that path without coupling the browser or SSH UI to
which carrier wins the D2 bakeoff. A carrier decision is made only after the same
workload is measured over V1, V2, and V3.

## Scope guardrails

- The agent-session GUI is future work and is not part of this wave.
- Host-owned state stays on the Mac daemon; Durable Objects coordinate and resume
  control-plane streams, but never become a terminal byte store.
- Terminal bytes, browser video, remote desktop, and file/media payloads stay on the
  stream plane. Workspace, feed, notifications, pairing, and signaling stay on the
  control plane.
- Direct Tailscale/WireGuard/LAN addresses are an explicit user-selected path and are
  authenticated with the pinned host identity. They do not become an implicit fallback
  for a failed cloud path.
- New UI must support Dynamic Type, VoiceOver, Reduce Motion and offline/reconnect
  states, and must cite the relevant Apple HIG guidance in its lane note.
