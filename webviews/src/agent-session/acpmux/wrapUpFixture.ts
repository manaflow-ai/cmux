// l10n-allow-file: debug fixture prompts and replies, not shipped UI.
// A turn still running whose newest call is a returned `mcp__acpmux__wrap_up` with a recap and a
// question, for `debug.agent_pane seed_rows` with `fixture: "wrap-up"`, so a capture shows the
// "Needs your input" card a running turn now draws the moment its wrap-up call returns (Leo,
// 2026-11-19, on the Needs your input cards: "odd looking / plus it's not instant yet"; turns.ts
// `liveWrapUp`). No turn summary follows: the turn has not ended.
import type { AcpmuxRow } from "./model";
import type { SeedSnapshotFields } from "./waitingSteersFixture";

const SECOND = 1_000;

/// The snapshot fields of a turn still running, which a debug seed sets beside these rows.
export const WRAP_UP_SNAPSHOT: SeedSnapshotFields = {
  isWorking: true,
  waitingSteers: undefined,
  newestOwnSteer: undefined,
  summary: {},
};

/// The prompt, the agent's reply, then its returned wrap-up call, from `at`.
export function wrapUpRows(at: number): AcpmuxRow[] {
  return [
    { id: "wrap-up-user", version: 1, at, kind: "user", text: "Fix the flaky retry test and land it" },
    {
      id: "wrap-up-reply",
      version: 1,
      at: at + 20 * SECOND,
      kind: "assistant",
      text: "The retry test waited on a real timer; it now uses the fake clock and passed 200 runs in a row.",
    },
    {
      id: "wrap-up-call",
      version: 1,
      at: at + 24 * SECOND,
      kind: "activity",
      toolCount: 1,
      items: [
        {
          id: "wrap-up-call-tool",
          kind: "tool" as const,
          text: "mcp__acpmux__wrap_up",
          tool: {
            id: "wrap-up-call-tool",
            title: "mcp__acpmux__wrap_up",
            kind: "other",
            status: "completed",
            inputSummary: JSON.stringify({
              recap: "Fixed the flaky retry test with the fake clock; 200 runs passed. CI has not run yet.",
              ask: "Open the PR and merge it once CI is green?",
              actions: ["Open and merge", "Open as draft", "Not now"],
            }),
          },
        },
      ],
    },
  ] as AcpmuxRow[];
}
