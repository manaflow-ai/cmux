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
import { BACKGROUND_END, footerLabel, turnSpan, turnView, WORKED, workedLabel } from "./turns";

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

// cmux#54927, again: "Worked for 0s" over a turn whose one piece of work was a subagent. cmux#55191
// dropped that fold, and the "Working for" that stood over the running turn then vanished at its end,
// its rows loose (Leo, 2026-11-25: "i think it was replacing the "worked for" as it went. let's just
// fix forward and improve it all"). The fold stays, and reads "0s" (Leo, 2026-11-27: "let's do not <1 but 0s
// and revert that situatoin").
const agentNamed = (state: "completed" | "failed") =>
  ({
    id: "n3",
    parent: null,
    name: "N3 daemon wiring move",
    kind: "general-purpose",
    state,
    startedAt: 2,
    endedAt: 2,
    background: false,
    ...(state === "failed" && { error: "Agent terminated early due to an API error. 500" }),
  }) as never;
const spawnCall = (status: string) =>
  ({
    id: "call",
    kind: "tool",
    tool: {
      id: "n3-call",
      title: "Agent",
      kind: "think",
      status,
      inputSummary: JSON.stringify({
        description: "N3 daemon wiring move",
        prompt: "move it",
        subagent_type: "general-purpose",
      }),
    },
  }) as never;

for (const state of ["completed", "failed"] as const)
  test(`a ${state} subagent's turn under a second keeps its fold, "Worked for 0s"`, () => {
    for (const agentFamily of ["claude", "codex"]) {
      const rows: AcpmuxRow[] = [
        row("prompt", 1, "user", { text: "Move the daemon wiring" }),
        row("act", 2, "activity", { items: [spawnCall(state)] }),
        row("group", 2, "subagents", { subagents: [agentNamed(state)] }),
        row("summary", 2, "turnSummary", { status: "completed", toolCount: 1, durationMs: 0, turnStartedAtMs: 2 }),
      ];
      const view = turnView([...withSubagentLines(rows)], new Set(), { agentFamily });
      const labels = view.filter((entry) => entry.kind === WORKED).map((entry) => workedLabel(t, entry));
      expect(labels).toHaveLength(1);
      expect(labels[0]).toStartWith("Worked for 0s");
    }
  });

test("a quiet background turn of a subagent's end under a second reads 0s, never <1s", () => {
  const rows = subagentOnlyTurn(true).map((entry) =>
    entry.id === `${BACKGROUND_END}-bg` ? { ...entry, durationMs: 0, turnStartedAtMs: 12 } : entry,
  );
  const view = turnView([...withSubagentLines(rows)], new Set(), { agentFamily: "claude" });
  for (const entry of view.filter((entry) => entry.kind === WORKED)) expect(workedLabel(t, entry)).not.toContain("<1s");
});

test("a turn's time under a second reads 0s, never <1s", () => {
  expect(turnSpan(0)).toBe("0s");
  expect(turnSpan(999)).toBe("0s");
  expect(turnSpan(1_000)).toBe("1s");
  expect(turnSpan(76_000)).toBe("1m 16s");
  expect(workedLabel(t, row("worked-x", 1, WORKED, { durationMs: 400, status: "completed" }))).toBe("Worked for 0s");
});

test("the same subagent turn that took 6s keeps its Worked for", () => {
  const rows: AcpmuxRow[] = [
    row("prompt", 1, "user", { text: "Move the daemon wiring" }),
    row("act", 2_000, "activity", { items: [spawnCall("completed")] }),
    row("group", 2_000, "subagents", { subagents: [agentNamed("completed")] }),
    row("summary", 7_000, "turnSummary", {
      status: "completed",
      toolCount: 1,
      durationMs: 6_000,
      turnStartedAtMs: 1_000,
    }),
  ];
  const view = turnView([...withSubagentLines(rows)], new Set(), { agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === WORKED).map((entry) => workedLabel(t, entry))).toEqual([
    "Worked for 6s",
  ]);
});

// Review on #54927: an Agent call no subagent row answers (it failed before acpmux named one) is the
// call's only trace. It never vanishes, even beside another subagent's row.
test("an Agent call whose subagent never got a row keeps its fold and its row", () => {
  const orphan = {
    id: "orphan",
    kind: "tool",
    tool: {
      id: "orphan-call",
      title: "Agent",
      kind: "think",
      status: "failed",
      inputSummary: JSON.stringify({ description: "Unknown kind", prompt: "go", subagent_type: "nope" }),
    },
  } as never;
  const rows: AcpmuxRow[] = [
    row("prompt", 1, "user", { text: "Two agents" }),
    row("act", 2, "activity", { items: [spawnCall("completed"), orphan] }),
    row("group", 2, "subagents", { subagents: [agentNamed("completed")] }),
    row("summary", 2, "turnSummary", { status: "completed", toolCount: 2, durationMs: 0, turnStartedAtMs: 2 }),
  ];
  const view = turnView([...withSubagentLines(rows)], new Set(), { agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === WORKED)).toHaveLength(1);
});

test("a lone subagent's turn with no recorded time keeps its fold, and its footer says no count", () => {
  const rows: AcpmuxRow[] = [
    row("prompt", 1, "user", { text: "Move the daemon wiring" }),
    row("act", 2, "activity", { items: [spawnCall("failed")] }),
    row("group", 2, "subagents", { subagents: [agentNamed("failed")] }),
    row("summary", 2, "turnSummary", { status: "completed", toolCount: 1 }),
  ];
  const view = turnView([...withSubagentLines(rows)], new Set(), { agentFamily: "claude" });
  expect(view.filter((entry) => entry.kind === WORKED).map((entry) => workedLabel(t, entry))).toEqual([
    "Worked for 0s",
  ]);
  const footer = view.find((entry) => entry.kind === "turnSummary")!;
  expect(footerLabel(t, footer)).toBeUndefined();
});
