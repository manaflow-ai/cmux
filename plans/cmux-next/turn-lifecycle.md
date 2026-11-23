# Agent chat: a turn's lifecycle, and the controls each state allows

Leo, 2026-11-22: "we need to be able to map out the lifecycle and what should reasonably be possible, when."

A chat has one turn state at a time. This page lists the states, how a chat moves between them, and which
of the turn's controls each state may show: the send slot (Send, Stop, Resume), Esc's stop, and Edit on
the turn's own prompt. A control that shows in a state that does not list it is a bug. The table below is
also the test's data: `webviews/test/turn-control-matrix.test.tsx` draws the real composer and the
turn's prompt bubble in every state and fails when what they draw differs from the row.

A single prompt's own stages (sending, queued, steer waiting, held, failed, read, answered) and each
stage's row actions (Copy, ✕, Edit in place, Edit and resend, Send now, Retry, Remove, Approve, Fork) are
acpmux's table: `cmux-tui/crates/acpmux-core/src/chat/prompt_lifecycle.rs` and its
`prompt_lifecycle.json`, checked by `conversation/promptLifecycle.test.tsx`. This page is the turn's side of
it: which stage the turn's own prompt is in while the turn is in each state.

## States

The composer reads every state from the snapshot alone (`turnPhase.ts`, `Composer.tsx`):

| State | The snapshot says |
| --- | --- |
| idle | connected; nothing runs; the last turn completed |
| stopped | connected; nothing runs; the last turn was stopped and acpmux can resume it (`resumable`); nothing queued runs next; no goal runs |
| stopped, goal runs | as stopped, but the chat's goal is active or running: the goal continues it, so the composer offers no Resume |
| starting | the agent is starting (`switching.phase` `starting`) and a prompt waits for it |
| working | a turn runs (`isWorking`), with or without prompts queued behind it |
| stopping | Stop was sent (`stopping`) and the turn has not ended |
| handing over | the turn ended and a queued prompt acpmux runs next has not started; at most 2 s (`composer/turnHandover.ts`) |
| offline, was working | the pane's link is down and the last snapshot said a turn runs; a Stop is kept and sent when the pane reconnects to that turn (`stopThroughReconnect.ts`) |
| offline, was stopped | the link is down and the last turn was stopped |

## Transitions

```
idle ──send──▶ working                      (starting first, if the agent must start)
starting ──agent up──▶ working
working ──Stop, or Esc Esc──▶ stopping ──turn ends──▶ stopped
working ──turn ends, queue empty──▶ idle
working ──turn ends, a queued prompt runs next──▶ handing over ──next turn starts──▶ working
stopped ──Resume (or Return in the empty composer)──▶ working
stopped ──send──▶ working
any ──link drops──▶ offline, was <state> ──link back──▶ <the daemon's state now>
```

## Controls

- **Empty**: what the send slot shows with nothing typed. **Draft**: with a prompt typed.
- **Esc**: what one Esc in the empty composer does. `arms` names Stop "Press Esc again to stop", and a
  second Esc stops (`escapeStop.ts`).
- **Own prompt Edit**: whether the prompt that opened the turn offers Edit (Edit and resend: a fork through
  the turn before it). Only once its turn has ended (acpmux's `answered` stage); never while the agent has
  read it and its turn runs (`read`), the case in Leo's screenshot.
  `-` where the turn has no prompt of its own on screen yet.

<!-- turn-controls:begin -->
| State | Empty | Draft | Esc | Own prompt Edit |
| --- | --- | --- | --- | --- |
| idle | none | Send | none | yes |
| stopped | Resume | Send | none | yes |
| stopped, goal runs | none | Send | none | yes |
| starting | Stop | Send | arms | - |
| working | Stop | Send | arms | no |
| stopping | Stopping… | Send | none | no |
| handing over | Stop | Send | arms | yes |
| offline, was working | Stop | Send | arms | no |
| offline, was stopped | none | Send | none | yes |
<!-- turn-controls:end -->

Why each cell is what it is:

- **Stop** shows wherever a turn runs or is about to (starting, handing over), so the slot never flickers
  between two turns, and offline too, where the press is kept, not dropped. It turns into "Stopping…" once
  sent; pressed again it sends Stop again. Esc does nothing more while stopping.
- **Send** shows with any draft in every state. Mid-turn it does what Return does: it steers an agent that
  steers, else queues behind the turn (`followUpMode.ts`). Offline it is held until the host can take it
  (`sendWhenReady.ts`). Claude's look draws no Send at rest without a draft; Codex's always draws it, so
  the empty column ignores Send.
- **Resume** shows only in the empty composer of a stopped turn the pane can reach, with nothing queued to
  run next and no goal running (`composer/resumeControl.ts`). Offline, the Resume would go nowhere.
- **Own prompt Edit**: a running turn's prompt is read, so editing it would rewrite what the agent is
  already acting on. When the turn ends (completed, stopped, or handed over to the next queued turn),
  Edit forks through the turn before and keeps both versions.
