// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// A seam the reader cannot see never splits a finished turn's run of calls (Leo, 2026-11-12,
// ask-bc2af01f6e, on a finished Claude turn whose calls drew line after line: "how come these aren't
// folded? they were missed in the logic?").
//
// Before: two runs joined only across a short note (turns.ts `mergeShortNotes`) or a message between
// agents (messageRuns.ts). Anything else that ended a run in direct.ts left two lines that no click
// folded together: a todo-list update (which moves to the turn's end, so nothing drew between the
// two runs), an agent message with no visible text, and a compaction with no message beside it.
// After: those runs draw as one line, in every family fold and both Claude arms.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { mergeShortNotes, turnView } from "../src/agent-session/acpmux/conversation/turns";

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const tool = (title: string, kind: string, fields: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: title,
  tool: { id: `tool-${(n += 1)}`, title, kind, status: "completed", ...fields },
});
const read = (path: string) => tool(`Read ${path}`, "read", { locations: [{ path }] });
const run = (command: string) => tool(command, "execute", { command, output: "ok\n" });
const activity = (items: AcpmuxActivity[], id: string) => row("activity", { id, items, toolCount: items.length });
const plan = (id: string) => row("plan", { id, plan: [{ content: "Look around", status: "completed" }] });

/// A finished turn: two runs of calls with `seam` between them, then the answer.
function turn(seam: AcpmuxRow[]): AcpmuxRow[] {
  return [
    row("user", { id: "prompt", text: "Look around" }),
    activity([run("ls"), read("/tmp/a")], "run-1"),
    ...seam,
    activity([run("git status"), read("/tmp/b")], "run-2"),
    row("assistant", { id: "answer", text: "Everything is in place." }),
    row("turnSummary", {
      id: "summary",
      status: "completed",
      durationMs: 60_000,
      toolCount: 4,
    }),
  ];
}

const SEAMS: Record<string, () => AcpmuxRow[]> = {
  "a todo-list update": () => [plan("todo")],
  "an agent message with no visible text": () => [row("assistant", { id: "blank", text: "\n\n" })],
  "a compaction with no message beside it": () => [
    row("compaction", {
      id: "compacted",
      compaction: {
        state: "completed",
        preTokens: 200_000,
        postTokens: 20_000,
      },
    }),
  ],
};

/// The drawn lines that hold calls: a folded run, or a message run's line.
const runLines = (view: readonly AcpmuxRow[]) =>
  view.filter((r) => (r.kind === "activity" && r.foldRun) || r.kind === "messageRun");

for (const [name, seam] of Object.entries(SEAMS)) {
  test(`Claude's in-place runs: ${name} between two runs draws one line`, () => {
    globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
    const view = turnView(turn(seam()), new Set(), { agentFamily: "claude" });
    expect(runLines(view)).toHaveLength(1);
    expect(view.map((r) => r.id)).not.toContain("run-2");
  });

  test(`an opened Worked for: ${name} between two runs draws one line`, () => {
    for (const agentFamily of ["claude", "codex"] as const) {
      const view = turnView(turn(seam()), new Set(["worked-prompt"]), {
        agentFamily,
      });
      expect(runLines(view)).toHaveLength(1);
    }
  });
}

test("a short note still joins two runs as a quiet line, and a takeaway still splits them", () => {
  const note = row("assistant", { id: "note", text: "Now the status." });
  const joined = mergeShortNotes([activity([run("ls")], "a"), note, activity([run("pwd")], "b")]);
  expect(joined).toHaveLength(1);
  expect(joined[0]!.items?.some((item) => item.kind === "note")).toBe(true);
  const takeaway = row("assistant", {
    id: "takeaway",
    text: "Found it?\n\nThe cache was stale.",
  });
  expect(mergeShortNotes([activity([run("ls")], "c"), takeaway, activity([run("pwd")], "d")])).toHaveLength(3);
});

test("two runs with nothing drawn between them are one run, keeping the first run's id", () => {
  const joined = mergeShortNotes([
    activity([run("ls")], "a"),
    row("assistant", { id: "empty", text: "" }),
    activity([run("pwd")], "b"),
    activity([read("/tmp/c")], "c"),
  ]);
  expect(joined).toHaveLength(1);
  expect(joined[0]!.id).toBe("a");
  expect(joined[0]!.toolCount).toBe(3);
  expect(joined[0]!.joined).toEqual(["a", "empty", "b", "c"]);
  // No quiet note line for words nobody can see.
  expect(joined[0]!.items?.some((item) => item.kind === "note")).toBe(false);
});

test("a run of a turn the agent ran on its own never joins the chat's own run beside it", () => {
  const background = { ...activity([run("gh run list")], "bg-run"), inBackground: "scheduled-1" };
  const joined = mergeShortNotes([background, activity([run("gh workflow run")], "own-run")]);
  expect(joined.map((r) => r.id)).toEqual(["bg-run", "own-run"]);
});

test("a compaction at a run's edge, or between two turns' runs, folds nothing", () => {
  globalThis.cmuxExperiments = { "claude-turn-fold": "runs" };
  const compaction = () => row("compaction", { compaction: { state: "failed", inferred: true } as never });
  const edge = [
    row("user", { id: "p-edge", text: "Go" }),
    activity([run("ls"), read("/tmp/a")], "edge-run"),
    compaction(),
    row("turnSummary", { id: "edge-summary", status: "completed", durationMs: 1_000, toolCount: 2 }),
  ];
  expect(turnView(edge, new Set(), { agentFamily: "claude" }).some((r) => r.kind === "messageRun")).toBe(false);
});
