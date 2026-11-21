// l10n-allow-file: debug fixture text, not shipped UI.
// Two finished subagents for `debug.agent_pane seed_rows` with `fixture: "subagent-report"`, so a
// capture reads the "Subagent finished" card in the real app (Leo, 2026-11-09: "whoa this isn't
// rendering the full message nor having a show more as it shuold"). The first carries its whole
// reply as acpmux now sends it (`result`): the card opens to all of it. The second has only acpmux's
// 240-character `lastMessage`, cut inside `**24 clean, f`: the card shows its whole blocks, no raw
// `**`, and Show more (subagents/wholeReport.ts), which reads its whole reply from its own records
// (`subagentReportLog`, seeded into the showcase's mock daemon).
import type { AcpmuxRow } from "./model";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

export const REPORT = [
  "I freed about 7 GiB on build-box. Free space is now **39 GiB**, still about 1 GiB under the 40 GiB floor. It read 22 GiB when you briefed me, but 32 GiB when I started deleting; I didn't cause that 10 GiB drop.",
  "",
  "**Deleted:**",
  "",
  "- **24 clean, finished worktrees** under ~/Projects/checkouts, each merged or closed.",
  "- **3 stale build dirs** from lanes that ended last week.",
  "",
  "Nothing else was touched.",
].join("\n");

/// acpmux's `lastMessage` of it (subagents.rs `truncate_last_message`): 239 characters and "…".
export const PREVIEW = `${Array.from(REPORT).slice(0, 239).join("")}…`;

const finished = (id: string, task: string, at: number, fields: Partial<Subagent>): Subagent => ({
  id,
  parent: null,
  name: task,
  kind: "general-purpose",
  task,
  state: "completed",
  startedAt: at,
  endedAt: at + 82 * 60_000,
  ...fields,
});

/// The capped subagent, whose card shows only `PREVIEW` until Show more reads its own records.
export const CAPPED_ID = "fixture-report-capped";

/// The capped subagent's own records in the chat's log, as acpmux writes them (subagents.rs): its
/// spawn, its whole reply tagged with it, and its end with only the capped `lastMessage`.
export function subagentReportLog(): { update: Record<string, unknown>; meta: Record<string, unknown> }[] {
  const change = { id: CAPPED_ID, parent: null, name: "Clean old repos (preview only)" };
  return [
    {
      update: { sessionUpdate: "subagent_spawned" },
      meta: { acpmux: { subagents: [{ ...change, state: "running" }] } },
    },
    {
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPORT } },
      meta: { acpmux: { subagent: CAPPED_ID } },
    },
    {
      update: { sessionUpdate: "subagent_state_update" },
      meta: { acpmux: { subagents: [{ id: CAPPED_ID, state: "completed", lastMessage: PREVIEW }] } },
    },
  ];
}

/// The ask, the agent's answer, and the two subagents it started, both finished, from `at`.
export function subagentReportRows(at: number): AcpmuxRow[] {
  return [
    { id: "report-ask", version: 1, at, kind: "user", text: "Clean old repos on build-box, twice" },
    {
      id: "report-answer",
      version: 1,
      at: at + 2_000,
      kind: "assistant",
      text: "Starting two cleaners; I'll report when both are back.",
    },
    {
      id: "report-group",
      version: 1,
      at: at + 3_000,
      kind: SUBAGENTS,
      subagents: [
        finished("fixture-report-whole", "Clean old repos (whole result)", at + 3_000, {
          result: REPORT,
          lastMessage: PREVIEW,
        }),
        finished(CAPPED_ID, "Clean old repos (preview only)", at + 4_000, { lastMessage: PREVIEW }),
      ],
    } as AcpmuxRow,
  ];
}
