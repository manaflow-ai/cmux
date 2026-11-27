// l10n-allow-file: gallery fixtures (sample prompts and subagent titles), not shipped UI.
// A quick turn whose only work was a subagent. cmux#55191 dropped its "Worked for 0s" fold, so the
// "Working for" that stood over the running turn vanished at its end and the subagent's row stood
// loose, a bare red dot on a failed one's mark (Leo, 2026-11-25: "dot on left weird / oh this is your
// "less than three tool calls it doesnt go into a worked for but rather just... stuff"", and "i think
// it was replacing the "worked for" as it went. let's just fix forward and improve it all").
// Now the turn keeps one line from its first frame to its end: "Working for 0s", then "Worked for
// 0s" (turns.ts `turnSpan`; Leo, 2026-11-27: "let's do not <1 but 0s and revert that situatoin"); a
// failed subagent's mark carries the failure's own glyph.
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

const NAME = "N3 daemon wiring move";

const spawn = (status: string) =>
  tool("Agent", "think", status, {
    inputSummary: JSON.stringify({ description: NAME, prompt: "move it", subagent_type: "general-purpose" }),
  });

const agentRow = (state: "running" | "completed" | "failed", minutes: number): AcpmuxRow =>
  row("subagents", minutes, {
    id: "quick-subagent-group",
    subagents: [
      {
        id: "n3",
        parent: null,
        name: NAME,
        kind: "general-purpose",
        state,
        startedAt: GALLERY_NOW - minutes * 60_000,
        ...(state !== "running" && { endedAt: GALLERY_NOW - minutes * 60_000 }),
        background: false,
        ...(state === "failed" && { error: "Agent terminated early due to an API error. 500" }),
      },
    ] as never,
  });

const ended = (state: "completed" | "failed", durationMs: number) =>
  chat([
    user("Move the daemon wiring", 1, { id: "quick-prompt" }),
    activity([spawn(state)], 1, { id: "quick-call" }),
    agentRow(state, 1),
    summary(1, { id: "quick-summary", status: "completed", toolCount: 1, durationMs }),
  ]);

const running = () =>
  chat(
    [
      user("Move the daemon wiring", 0, { id: "quick-prompt" }),
      activity([spawn("running")], 0, { id: "quick-call" }),
      agentRow("running", 0),
    ],
    { isWorking: true, turnStartedAtMs: GALLERY_NOW - 400 },
  );

export default agentPaneEntry({
  id: "agent-pane.quick-subagent-turn",
  title: "A quick subagent turn: one Worked for, 0s, a failure badge on the mark",
  area: "Agent pane",
  height: 320,
  covers: [
    "agent-session/acpmux/conversation/turns.ts",
    "agent-session/acpmux/conversation/WorkingFor.tsx",
    "agent-session/acpmux/conversation/TurnTokens.tsx",
    "agent-session/acpmux/subagents/SubagentDoneLine.tsx",
    "agent-session/acpmux/subagents/subagents.css",
  ],
  keywords: ["worked for", "working for", "0s", "subagent", "failed", "dot"],
  variants: {
    running: {
      note: 'Running, 0.4 s in: "Working for 0s" over the work from the first frame, no bare "Working" that swaps.',
      snapshot: running(),
    },
    "ended-quick": {
      note: 'Ended under a second: the same line reads "Worked for 0s"; the subagent folds under it as a call.',
      snapshot: ended("completed", 400),
    },
    "ended-failed": {
      note: "A failed subagent under a second: its mark carries the failure's glyph as a badge, not a stray red dot.",
      snapshot: ended("failed", 400),
    },
    "ended-6s": {
      note: 'The same turn at 6 s: "Worked for 6s", as before.',
      snapshot: ended("completed", 6_000),
    },
  },
});
