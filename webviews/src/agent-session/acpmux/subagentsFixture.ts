// l10n-allow-file: debug fixture text, not shipped UI.
// The subagent tray's life for `debug.agent_pane seed_rows` with `fixture: "subagents"`, so a capture
// shows the tray (subagents/SubagentTray.tsx, trayMotion.tsx) moving in the real app: the showcase
// mock never starts a subagent. `count` picks the step, and each call replaces the rows with that
// step's, so the capture's own steps set the pace (and click the tray's header between them to fold
// it). No timer: nothing runs between calls. Seed it in a chat that has a session (the capture state
// sends a prompt first): the tray's entrance plays only in one (App.tsx trayEnters).
//   0  the ask and the agent's answer, no subagent
//   1  two background subagents start: the tray eases in, "2 subagents running"
//   2  a received agent message arrives in the transcript beside the tray
//   3  the first subagent finishes: the count ticks to 1, its line ticks to its end
//   4  the second finishes: the header ticks to the finished count
//   5  the subagents' group is gone (as when the chat's rows load without it): the tray leaves
// `agents` (2 by default, up to SUBAGENT_FIXTURE_MAX) is how many start at step 1: past the reviewer
// and the auditor, helpers that stay running through every step, so a capture can open 3 or more
// subagents' panes and record where each lands (design/pane-placement.md).
import { received } from "./incomingFixture";
import type { AcpmuxRow } from "./model";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

export const SUBAGENT_TRAY_STEPS = 6;
/// The most subagents `agents` starts.
export const SUBAGENT_FIXTURE_MAX = 8;

const REVIEWER: Subagent = {
  id: "fixture-reviewer",
  parent: null,
  name: "Reviewer",
  kind: "general-purpose",
  task: "Review the tray motion diff",
  state: "running",
  startedAt: 0,
  background: true,
  action: "Read trayMotion.tsx",
};
const AUDITOR: Subagent = {
  id: "fixture-auditor",
  parent: null,
  name: "Auditor",
  kind: "Explore",
  task: "Audit the bottom stack for motion that skips the tokens",
  state: "running",
  startedAt: 0,
  background: true,
  action: "Search conversation.css",
};
const MESSAGE = {
  id: "msg_5b8e2f0c7a1d4e6f9b3c2a1d0e8f7a6b",
  thread: "msg_5b8e2f0c7a1d4e6f9b3c2a1d0e8f7a6b",
  sender: "cli",
  name: "subsession-card",
  body: "The tray recording is next; tell me when both reviewers are back.",
};

/// Helper `n` (from 1), started a second after the one before it, past the auditor.
const helper = (n: number): Subagent => ({
  id: `fixture-helper-${n}`,
  parent: null,
  name: `Helper ${n}`,
  kind: "Explore",
  task: `Read part ${n} of the pane placement rules`,
  state: "running",
  startedAt: 0,
  background: true,
  action: "Read pane-placement.md",
});

/// The rows of step `step` (0 to SUBAGENT_TRAY_STEPS - 1), from the time `at` the fixture began,
/// with `agents` subagents started at step 1 (2: the reviewer and the auditor).
export function subagentTrayRows(step: number, at: number, agents = 2): AcpmuxRow[] {
  const rows: AcpmuxRow[] = [
    { id: "subagents-ask", version: 1, at, kind: "user", text: "Review the tray motion and audit the bottom stack" },
    {
      id: "subagents-answer",
      version: 1,
      at: at + 3_000,
      kind: "assistant",
      text: "Starting a reviewer and an auditor in the background; I'll report when both are back.",
    },
  ];
  if (step >= 1 && step < 5) {
    // The reviewer starts first, so it leads the tray's list.
    const ended = (agent: Subagent, start: number, after: number, done: boolean): Subagent =>
      done
        ? { ...agent, startedAt: at + start, state: "completed", endedAt: at + after, action: undefined }
        : { ...agent, startedAt: at + start };
    rows.push({
      id: "subagents-group",
      version: step,
      at: at + 4_000,
      kind: SUBAGENTS,
      subagents: [
        ended(REVIEWER, 4_000, 40_000, step >= 3),
        ended(AUDITOR, 5_000, 55_000, step >= 4),
        ...Array.from({ length: Math.min(Math.max(Math.floor(agents), 2), SUBAGENT_FIXTURE_MAX) - 2 }, (_, index) =>
          ended(helper(index + 1), 6_000 + index * 1_000, 0, false),
        ),
      ],
    } as AcpmuxRow);
  }
  if (step >= 2) rows.push(received("subagents-message", at + 20_000, MESSAGE));
  return rows;
}
