// l10n-allow-file: test fixture todo items and tool titles, not shipped UI.
// The activity line (cx-ncc.102, Claude Code desktop's in-session status; Debug Settings
// `agent.sessionStatus`): while a turn with a todo list runs, the list is pinned under the work
// (toggle or not, Leo 2026-11-03) and, with the toggle, one line under it names what the agent is
// doing now, in the "Working for" status's place. A turn without a list draws as before.
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxPlanEntry, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ACTIVITY_LINE, turnView, WORKING } from "../src/agent-session/acpmux/conversation/turns";

// This file covers the `runs` arm of liveTurnWork.experiment.ts: a running turn keeps its finished
// runs in sight until it ends. The shipped `line` arm (one live line, as chatgpt.com draws a running
// turn) is covered by live-turn-one-line.test.ts.
const liveTurnArmsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...liveTurnArmsBefore, "live-turn-work": "runs" };
});
afterAll(() => {
  globalThis.cmuxExperiments = liveTurnArmsBefore;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const tool = (id: string, status: string) =>
  row(id, "activity", { items: [{ kind: "tool", text: id, tool: { id, title: id, kind: "edit", status } }] });
const plan = (...entries: [string, AcpmuxPlanEntry["status"]][]) =>
  row("plan", "plan", { plan: entries.map(([content, status]) => ({ content, status })) });
const steps = plan(["Reproduce", "completed"], ["Reserve space", "in_progress"], ["Add a test", "pending"]);
const live = (rows: AcpmuxRow[], sessionStatus: boolean) =>
  turnView(rows, new Set(), { working: true, sessionStatus }).filter((shaped) => shaped.kind !== "date");
const kinds = (rows: AcpmuxRow[]) => rows.map((shaped) => `${shaped.kind}:${shaped.id}`);

test("the toggle off pins the list under the work, the live line under it", () => {
  const rows = [row("u", "user"), steps, tool("edit-a", "in_progress")];
  // The edit in flight leaves its run for the live line, which names it.
  expect(kinds(live(rows, false))).toEqual(["user:u", "plan:plan", "thinking:thinking-live"]);
});

test("the toggle on moves the list under the work, with the activity line in the status's place", () => {
  const rows = [row("u", "user"), steps, tool("edit-a", "in_progress")];
  expect(kinds(live(rows, true))).toEqual(["user:u", "plan:plan", `${ACTIVITY_LINE}:${ACTIVITY_LINE}-u`]);
});

test("the activity line replaces WorkingFor when the session status list is enabled", () => {
  const rows = live([row("u", "user"), steps, tool("edit-a", "in_progress")], true);
  expect(rows.some((drawn) => drawn.kind === ACTIVITY_LINE)).toBe(true);
  expect(rows.some((drawn) => drawn.kind === WORKING)).toBe(false);
});

test("the activity line names the running call, else the todo in progress, timed from the prompt", () => {
  const user = row("u", "user");
  const running = live([user, steps, tool("edit-a", "in_progress")], true).at(-1)!;
  expect(running.text).toBe("edit-a");
  expect(running.at).toBe(user.at);
  // It carries no items, so Find never counts the call's output on it a second time.
  expect(running.items).toBeUndefined();
  const between = live([user, steps, tool("edit-a", "completed")], true).at(-1)!;
  expect(between.text).toBe("Reserve space");
  // What it names is in its version, so the memoized row redraws when the call changes.
  expect(between.version).not.toBe(running.version);
});

test("a running command reads as itself", () => {
  const command = row("run", "activity", {
    items: [
      {
        kind: "tool",
        text: "Ran bun test",
        tool: { id: "run", title: "Ran bun test", kind: "execute", status: "in_progress", command: "bun test grid" },
      },
    ],
  });
  expect(live([row("u", "user"), steps, command], true).at(-1)!.text).toBe("bun test grid");
});

test("the activity line names an edited file by its name, not its path", () => {
  const path = "/tmp/demo/storefront/src/components/ProductGrid.module.css";
  const edit = row("edit-c", "activity", {
    items: [
      {
        kind: "tool",
        text: `Edit ${path}`,
        tool: { id: "edit-c", title: `Edit ${path}`, kind: "edit", status: "in_progress", locations: [{ path }] },
      },
    ],
  });
  expect(live([row("u", "user"), steps, edit], true).at(-1)!.text).toBe("Edit ProductGrid.module.css");
});

test("a call whose path arrives after its title redraws the line", () => {
  const edit = (locations?: { path: string }[]) =>
    row("edit-b", "activity", {
      items: [
        {
          kind: "tool",
          text: "Edit",
          tool: { id: "edit-b", title: "Edit", kind: "edit", status: "in_progress", locations },
        },
      ],
    });
  const before = live([row("u", "user"), steps, edit()], true).at(-1)!;
  const after = live([row("u", "user"), steps, edit([{ path: "src/grid.css" }])], true).at(-1)!;
  expect(after.text).toBe("Edit grid.css");
  expect(after.version).not.toBe(before.version);
});

test("while the answer streams the list stays pinned under it and the live line under both", () => {
  const rows = [row("u", "user"), steps, tool("edit-a", "completed"), row("answer", "assistant", { text: "Done" })];
  expect(kinds(live(rows, true))).toEqual([
    "user:u",
    "activity:edit-a",
    "assistant:answer",
    "plan:plan",
    "thinking:thinking-live",
  ]);
});

test("a turn without a list draws as before with the toggle on", () => {
  const rows = [row("u", "user"), tool("edit-a", "in_progress")];
  expect(kinds(live(rows, true))).toEqual(kinds(live(rows, false)));
});

test("a finished turn draws no activity line", () => {
  const rows = [
    row("u", "user"),
    steps,
    tool("edit-a", "completed"),
    row("answer", "assistant", { text: "Done" }),
    row("s", "turnSummary", { status: "completed" }),
  ];
  const shaped = turnView(rows, new Set(), { working: false, sessionStatus: true });
  expect(shaped.some((drawn) => drawn.kind === ACTIVITY_LINE)).toBe(false);
});
