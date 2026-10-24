// Consecutive tool calls consolidate into fewer rows, as Claude desktop and Codex draw them (Leo
// 2026-10-21: "it can consolidate a ton of these tool calls and such tbh in the ui"): a finished run
// of reads, searches and commands is one counted line ("Read 2 files, ran a search, ran 2
// commands"), a thought between calls never splits a group, and coordination cards and failures
// stay in sight.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { runStretches, ToolRows } from "../src/agent-session/acpmux/conversation/TurnRows";
import { toolGroupLabel, toolGroups } from "../src/agent-session/acpmux/conversation/toolGroups";
import { toolRunSummary } from "../src/agent-session/acpmux/conversation/toolRunSummary";
import { translate } from "../src/agent-session/acpmux/i18n";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const call = (id: string, kind: string, extra: Record<string, unknown> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: id,
  tool: { id, title: id, kind, status: "completed", ...extra },
});
const read = (path: string) => call(`Read ${path}`, "read", { locations: [{ path }] });
const search = (pattern: string) => call(`Grep ${pattern}`, "search");
const command = (line: string, extra: Record<string, unknown> = {}) =>
  call(line, "execute", { command: line, ...extra });
const edit = (path: string) =>
  call(`Edit ${path}`, "edit", { diffs: [{ path, oldText: "a\n", newText: "b\n" }], locations: [{ path }] });
const thought = (text: string): AcpmuxActivity => ({ kind: "thought", text, startedAt: 0, endedAt: 4_000 });
const message: AcpmuxActivity = {
  kind: "tool",
  text: "Sent message to coordinator",
  tool: {
    id: "send",
    title: "cmux send",
    kind: "execute",
    status: "completed",
    command: "cmux send --to coordinator --message done",
  },
};

const run = (items: AcpmuxActivity[], foldRun = true): AcpmuxRow => ({
  id: "run",
  version: 1,
  at: 1,
  kind: "activity",
  settled: true,
  foldRun,
  items,
});
const drawn = (row: AcpmuxRow) => renderToStaticMarkup(<ToolRows row={row} />).replace(/<[^>]+>/g, " ");
const lines = (row: AcpmuxRow) => (renderToStaticMarkup(<ToolRows row={row} />).match(/aria-expanded/g) ?? []).length;

const longThought = (topic: string) => thought(`Now I should look at ${topic} to see how the retry is wired up.`);

test("reads, searches and commands with thoughts between them are one counted line", () => {
  const items = [
    read("src/retry.ts"),
    longThought("the helper"),
    search("backoff"),
    longThought("the tests"),
    command("bun test retry"),
    read("src/helper.ts"),
    longThought("the log"),
    command("git log -3"),
  ];
  const html = drawn(run(items));
  expect(html).toContain("Read 2 files, ran a search, ran 2 commands");
  expect(lines(run(items))).toBe(1);
  // Closed until opened: no call shows under the line.
  expect(html).not.toContain("bun test retry");
});

test("a thought between two calls of one kind stays inside their group", () => {
  const items = [read("a.ts"), longThought("b"), read("b.ts"), longThought("c"), read("c.ts")];
  const groups = toolGroups(items);
  expect(groups).toHaveLength(1);
  expect(groups[0]).toMatchObject({ type: "group", kind: "reads" });
  const group = groups[0] as Extract<(typeof groups)[number], { type: "group" }>;
  expect(group.items).toEqual(items);
  expect(toolGroupLabel(translate, "reads", group.items)).toBe("Read 3 files");
  // A thought after the last call ends the group, in its place.
  const trailing = toolGroups([command("ls"), command("pwd"), longThought("next")]);
  expect(trailing.map((entry) => entry.type)).toEqual(["group", "item"]);
  expect(toolGroupLabel(translate, "commands", (trailing[0] as { items: AcpmuxActivity[] }).items)).toBe(
    "Ran 2 commands",
  );
  // Between calls of different kinds a thought keeps its own row.
  expect(toolGroups([read("a.ts"), longThought("x"), command("ls")]).map((entry) => entry.type)).toEqual([
    "item",
    "item",
    "item",
  ]);
});

test("an edit folds with the work around it, named on the line in the order it came", () => {
  const items = [read("a.ts"), search("retry"), command("ls"), edit("src/a.ts"), command("bun test"), read("b.ts")];
  const stretches = runStretches(run(items), toolGroups(items));
  expect(stretches.map((stretch) => stretch.fold)).toEqual([true]);
  const html = drawn(run(items));
  expect(html).toContain("Read 2 files, ran a search, ran 2 commands, edited a file");
  expect(lines(run(items))).toBe(1);
});

test("a coordination card stays in sight; the calls around it still fold", () => {
  const items = [read("a.ts"), command("ls"), message, command("bun test"), read("b.ts"), read("c.ts")];
  const stretches = runStretches(run(items), toolGroups(items));
  expect(stretches.map((stretch) => stretch.fold)).toEqual([true, false, true]);
  const html = drawn(run(items));
  expect(html).toContain("Read a file, ran a command");
  // Named in the order the run did them: the command came before the reads.
  expect(html).toContain("Ran a command, read 2 files");
});

test("a failed call is counted on the run's line", () => {
  const items = [read("a.ts"), command("grep -r nope", { exitCode: 1 }), command("ls")];
  expect(drawn(run(items))).toContain("1 failed");
});

test("a run that is not folded keeps every entry on its own line", () => {
  const items = [read("a.ts"), command("ls"), edit("src/a.ts"), read("b.ts")];
  const stretches = runStretches(run(items, false), toolGroups(items));
  expect(stretches).toHaveLength(1);
  expect(stretches[0]!.fold).toBe(false);
});

test("the summary counts distinct files read, and searches apart from reads", () => {
  const items = [read("a.ts"), read("a.ts"), read("b.ts"), search("x"), search("y")];
  expect(toolRunSummary(translate, items)).toBe("Read 2 files, ran 2 searches");
});

test("an ended turn's opened Worked for folds a run that edited, edit and all", () => {
  const at = (n: number) => 1_000 * n;
  const rows: AcpmuxRow[] = [
    { id: "u", kind: "user", version: 1, at: at(1), text: "Add retries" },
    {
      id: "work",
      kind: "activity",
      version: 1,
      at: at(2),
      items: [read("a.ts"), longThought("a"), read("b.ts"), search("retry"), edit("src/a.ts"), command("bun test")],
    },
    { id: "done", kind: "assistant", version: 1, at: at(3), text: "Retries are in." },
    { id: "s", kind: "turnSummary", version: 1, at: at(4), status: "completed", toolCount: 5 },
  ];
  const work = turnView(rows, new Set(["worked-u"]), { liveRuns: true }).find(
    (entry) => entry.kind === "activity" && entry.id.startsWith("work") && entry.settled,
  )!;
  expect(work.foldRun).toBe(true);
  const html = drawn(work);
  expect(html).toContain("Read 2 files, ran a search, edited a file, ran a command");
  expect(lines(work)).toBe(1);
  // The reply is never folded: it stays its own row after the fold.
  expect(turnView(rows, new Set(), { liveRuns: true }).some((entry) => entry.id === "done")).toBe(true);
});
