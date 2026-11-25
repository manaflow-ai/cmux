// cmux#54927: a finished turn whose only row was a subagent's end drew a collapsible "0 tool calls"
// line over it ("this 0 tool calls thing is a tad bit weird"). A fold with no time and nothing
// counted says nothing, so it is no fold: its rows draw as they ran, as Claude's and Codex's apps
// draw a lone subagent. A count, when there is one, still reads as before.
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { translate, type Translate } from "../i18n";
import { withSubagentLines } from "../subagents/runningTray";
import { SUBAGENT_DONE } from "../subagents/subagentRows";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { BACKGROUND_END, footerLabel, turnView, WORKED, workedLabel } from "./turns";

const t: Translate = (key, values) => translate(key, values, "en");

const row = (id: string, at: number, kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  at,
  kind,
  version: 1,
  ...fields,
});

/// A prompt's turn, then a turn the agent ran on its own when its reviewer subagent finished: its
/// only row is the subagent's group, and its end record carries no time and no calls.
const subagentOnlyTurn = (quiet: boolean): AcpmuxRow[] => [
  row("prompt-1", 1, "user", { text: "Review the PR" }),
  row("answer-1", 2, "assistant", { text: "Started a reviewer." }),
  row("summary-1", 3, "turnSummary", { status: "completed" }),
  row("backgroundTurn-bg", 4, BACKGROUND_TURN, {
    background: { id: "bg", trigger: "task_notification", running: false, quiet },
  }),
  row("group", 5, "subagents", {
    inBackground: "bg",
    subagents: [
      {
        id: "reviewer",
        parent: null,
        name: "Correctness review PR 53370",
        kind: "general-purpose",
        state: "completed",
        startedAt: 5,
        endedAt: 11,
        background: true,
      },
    ],
  }),
  row(`${BACKGROUND_END}-bg`, 12, "turnSummary", { status: "completed", inBackground: "bg", toolCount: 0 }),
];

for (const quiet of [true, false])
  test(`a ${quiet ? "quiet" : "loud"} turn of a subagent's end alone draws no "0 tool calls" fold`, () => {
    for (const agentFamily of ["claude", "codex"]) {
      const view = turnView([...withSubagentLines(subagentOnlyTurn(quiet))], new Set(), { agentFamily });
      const labels = view.filter((entry) => entry.kind === WORKED).map((entry) => workedLabel(t, entry));
      expect(labels.filter((label) => /\b0 tool calls\b/.test(label) || label === "")).toEqual([]);
      // The subagent's end stays in sight, in its place, not folded away under an empty line.
      expect(view.filter((entry) => entry.kind === SUBAGENT_DONE).map((entry) => entry.id)).toHaveLength(1);
      expect(view.at(-1)?.kind).toBe("turnSummary");
    }
  });

test("a line with no time and no calls says nothing; with calls it counts them", () => {
  const worked = (fields: Partial<AcpmuxRow>) => row("worked-x", 1, WORKED, fields);
  expect(workedLabel(t, worked({ toolCount: 0 }))).toBe("");
  expect(workedLabel(t, worked({}))).toBe("");
  expect(workedLabel(t, worked({ toolCount: 1 }))).toBe("1 tool call");
  expect(workedLabel(t, worked({ toolCount: 3 }))).toBe("3 tool calls");
  // A footer with nothing to say draws no words.
  expect(footerLabel(t, row("summary", 1, "turnSummary", { status: "completed", toolCount: 0 }))).toBeUndefined();
  expect(footerLabel(t, row("summary", 1, "turnSummary", { status: "completed", toolCount: 2 }))).toBe("2 tool calls");
});
