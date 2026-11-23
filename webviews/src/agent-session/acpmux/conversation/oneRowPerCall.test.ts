// l10n-allow-file: test fixtures.
// One tool call is one row from start to finish in a running turn (Leo, 2026-11-07: "sometimes you
// can just combine the, like, whatever command or action you're doing sooner than you do"): a call
// pending (Claude Code names it as its block starts, before any input), running and done is drawn
// in exactly one row at each step, and that row keeps its id across them, so it updates in place.
// His capture: a pending Write's own row ("Writing a file") over the live line naming the same call
// ("Write 12s").
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { turnView } from "./turns";

// This file covers the `line` arm of liveTurnWork.experiment.ts (the shipped arm is `runs`).
beforeEach(() => {
  globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "live-turn-work": "line" };
});
afterEach(() => {
  delete globalThis.cmuxExperiments;
});

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const J = JSON.stringify;
const writeInput = J({ file_path: "/src/gen.py", content: "print(1)\n" });
const editInput = J({ file_path: "/src/a.ts", old_string: "a", new_string: "b" });

/// Each kind's call as Claude Code (through acpmux, claude_stdio/early_calls.rs) sends it: named as
/// its block starts (pending, its bare tool name, no input), whole once its input came
/// (in_progress), then done.
const KINDS: Record<string, { pending: Partial<Tool>; running: Partial<Tool>; done: Partial<Tool> }> = {
  Write: {
    pending: { title: "Write", kind: "edit" },
    running: { title: "Write gen.py", kind: "edit", inputSummary: writeInput },
    done: {
      title: "Write gen.py",
      kind: "edit",
      inputSummary: writeInput,
      diffs: [{ path: "/src/gen.py", newText: "print(1)\n" }],
    },
  },
  Edit: {
    pending: { title: "Edit", kind: "edit" },
    running: { title: "Edit a.ts", kind: "edit", inputSummary: editInput },
    done: {
      title: "Edit a.ts",
      kind: "edit",
      inputSummary: editInput,
      diffs: [{ path: "/src/a.ts", oldText: "a\n", newText: "b\n" }],
    },
  },
  Read: {
    pending: { title: "Read", kind: "read" },
    running: { title: "Read a.ts", kind: "read", locations: [{ path: "/src/a.ts" }] },
    done: { title: "Read a.ts", kind: "read", locations: [{ path: "/src/a.ts" }] },
  },
  Bash: {
    pending: { title: "Bash", kind: "execute" },
    running: { title: "Bash", kind: "execute", command: "ls -la" },
    done: { title: "Bash", kind: "execute", command: "ls -la", output: "total 0" },
  },
  Grep: {
    pending: { title: "Grep", kind: "search" },
    running: { title: "grep foo", kind: "search", inputSummary: J({ pattern: "foo" }) },
    done: { title: "grep foo", kind: "search", inputSummary: J({ pattern: "foo" }) },
  },
  Glob: {
    pending: { title: "Glob", kind: "search" },
    running: { title: "Glob **/*.ts", kind: "search", inputSummary: J({ pattern: "**/*.ts" }) },
    done: { title: "Glob **/*.ts", kind: "search", inputSummary: J({ pattern: "**/*.ts" }) },
  },
  WebFetch: {
    pending: { title: "WebFetch", kind: "fetch" },
    running: { title: "WebFetch", kind: "fetch", inputSummary: J({ url: "https://example.test" }) },
    done: { title: "WebFetch", kind: "fetch", inputSummary: J({ url: "https://example.test" }) },
  },
  MCP: {
    pending: { title: "mcp__repo__grep", kind: "other" },
    running: { title: "mcp__repo__grep", kind: "other", inputSummary: J({ q: "x" }) },
    done: { title: "mcp__repo__grep", kind: "other", inputSummary: J({ q: "x" }) },
  },
};

const call = (fields: Partial<Tool>, status: string): AcpmuxActivity => ({
  kind: "tool",
  text: fields.title ?? "",
  tool: { id: "c1", title: "", kind: "other", ...fields, status } as Tool,
});

const view = (items: AcpmuxActivity[]) =>
  turnView(
    [
      { id: "p1", version: 1, at: 1_000, kind: "user", text: "go" },
      { id: "a1", version: 1, at: 2_000, kind: "activity", items },
    ],
    new Set(),
    { now: 20_000, working: true },
  );

/// The ids of the drawn rows that show call c1: a run holding it, or the live line naming it.
function rowsShowing(rows: AcpmuxRow[]): string[] {
  return rows
    .filter((row) =>
      row.kind === "activity"
        ? (row.items ?? []).some((item) => item.tool?.id === "c1")
        : row.kind === "thinking" && row.doing !== undefined && (row.doingCall ?? "c1") === "c1",
    )
    .map((row) => row.id);
}

// Drawn once while it is pending and runs: the live line. The moment it completes the line reads
// Thinking (Leo, 2026-11-07: "Why don't we just immediately switch to the thinking?"; takes back the
// held finished call of #29938 and #37568), and the call draws no row while the turn runs
// (liveTurnWork.experiment.ts `line`, as chatgpt.com draws a running turn).
for (const [kind, states] of Object.entries(KINDS))
  test(`${kind}: one row from pending to running, then none the moment it completes`, () => {
    const steps = [
      rowsShowing(view([call(states.pending, "pending")])),
      rowsShowing(view([call(states.running, "in_progress")])),
      rowsShowing(view([call(states.done, "completed")])),
    ];
    for (const step of steps.slice(0, 2)) expect(step).toHaveLength(1);
    expect(new Set(steps.slice(0, 2).flat()).size).toBe(1);
    expect(steps[2]).toEqual([]);
  });

test("a Write named before its input reads as the row it becomes: Writing a file, then Writing gen.py", () => {
  const line = (items: AcpmuxActivity[]) => view(items).find((row) => row.kind === "thinking");
  expect(line([call(KINDS.Write!.pending, "pending")])?.doing).toBe("Writing a file");
  const running = line([call(KINDS.Write!.running, "in_progress")]);
  expect(running?.doing).toBe("Writing gen.py");
  // The line carries the call's id, so it updates in place rather than rolling a new step in.
  expect(running?.doingCall).toBe("c1");
  // Done: the line reads Thinking at once.
  expect(line([call(KINDS.Write!.done, "completed")])?.doing).toBeUndefined();
});

test("a finished Write leaves no row once the next call starts, as any finished step does", () => {
  const rows = view([
    call(KINDS.Write!.done, "completed"),
    {
      ...call(KINDS.Read!.running, "in_progress"),
      tool: { ...call(KINDS.Read!.running, "in_progress").tool!, id: "c2" },
    },
  ]);
  expect(rowsShowing(rows)).toEqual([]);
  expect(rows.find((row) => row.kind === "thinking")?.doingCall).toBe("c2");
});

test("an edit waiting on its permission is drawn once: its own row, never the live line too", () => {
  const rows = view([call({ title: "Write gen.py", kind: "edit", inputSummary: writeInput }, "pending")]);
  expect(rowsShowing(rows)).toEqual(["a1"]);
});

test("an ended turn draws no edited-files card for a Write that never got its input", () => {
  // The turn was stopped while Claude Code still wrote the Write's input: the call never ran.
  const rows = turnView(
    [
      { id: "p1", version: 1, at: 1_000, kind: "user", text: "go" },
      { id: "a1", version: 1, at: 2_000, kind: "activity", items: [call(KINDS.Write!.pending, "pending")] },
      { id: "s1", version: 1, at: 3_000, kind: "turnSummary", status: "cancelled", durationMs: 2_000 },
    ],
    new Set(),
    { now: 20_000, working: false },
  );
  expect(rows.filter((row) => row.ended && (row.items ?? []).length)).toEqual([]);
  expect(rows.flatMap((row) => row.items ?? []).map((item) => item.tool?.id)).not.toContain("c1");
});
