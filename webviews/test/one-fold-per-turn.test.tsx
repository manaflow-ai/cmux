// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A finished turn has one fold, also when the person steered it mid-turn (Leo, 2026-11-07, on a
// closed "Worked for 5m 15s" with "Finished 2 background tasks and ran 8 commands" as a second
// top-level row under it: "this could have been, like, tucked inside the worked for" and "when you
// open the worked for, that, like, finished two, whatever, that's already automatically expanded, so
// it's as if you just expanded the whole worked for entirely"). Closed, the turn draws its Worked for
// and the replies and the steer it never hides (cmux#37245), and no run line beside them; opened, its
// run lines draw already open. A turn without a steer folds as before.
// Gallery: agent-pane.one-fold-per-turn.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { layoutConversation, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";

const START = Date.UTC(2026, 10, 7, 9, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const shell = (id: string, command: string, background = false): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: {
    id,
    title: command,
    kind: "execute",
    status: "completed",
    command,
    ...(background && { background: { state: "completed" as const, endedAt: START + 200_000 } }),
  },
});
const calls = (id: string, second: number, commands: string[], background = 0): AcpmuxRow =>
  row(id, "activity", second, {
    items: commands.map((command, index) => shell(`${id}-${index}`, command, index < background)),
  });

/// Leo's turn: two background builds and six commands, a reply, his steer, two more commands, the
/// answer.
const steered: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Land the fold fix" }),
  calls("t-1", 1, ["cmux-ci build", "cmux-ci test", "git status", "git diff", "rg fold", "bun test a"], 2),
  row("a-before", "assistant", 120, { text: "Both builds are running. I'm reading the fold code meanwhile." }),
  row("s-1", "user", 130, { text: "Also check the nightly", steer: "landed" }),
  calls("t-2", 131, ["gh run list", "gh run view"]),
  row("a-final", "assistant", 300, { text: "The nightly is green and the fix is up for review." }),
  row("s-0", "turnSummary", 315, { status: "completed", durationMs: 315_000, toolCount: 10 }),
];
const REPLIES = ["a-before", "s-1", "a-final"];

/// The same turn with no steer: the reply before it is a short note.
const plain = steered.filter((shown) => shown.id !== "s-1");

const FAMILIES = ["claude", "codex", "gemini", "muse", undefined];
const view = (rows: AcpmuxRow[], family: string | undefined, open = false) =>
  turnView(rows, new Set(open ? [`${WORKED}-u-0`] : []), { agentFamily: family, now: START + 400_000 });
/// A row that folds something away at the top level: the turn's Worked for or a run's line.
const folds = (rows: AcpmuxRow[]) => rows.filter((shown) => shown.kind === WORKED || shown.kind === "activity");

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: a steered turn closes to one fold, its replies and steer in sight`, () => {
    const closed = view(steered, family);
    const top = folds(closed);
    expect(top.map((shown) => shown.kind)).toEqual([WORKED]);
    expect(top[0]!.foldOpen).toBe(false);
    // Replies are never folded away (cmux#37245): the reply before the steer, the steer, the answer.
    const order = closed.filter((shown) => REPLIES.includes(shown.id)).map((shown) => shown.id);
    expect(order).toEqual(REPLIES);
    expect(closed.indexOf(top[0]!)).toBeLessThan(closed.findIndex((shown) => shown.id === "a-before"));
  });

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: opening a steered turn's Worked for draws its run lines open`, () => {
    const opened = view(steered, family, true);
    const runs = opened.filter((shown) => shown.kind === "activity");
    expect(runs.map((shown) => shown.id)).toEqual(["t-1", "t-2"]);
    for (const run of runs) {
      expect(run.foldRun).toBe(true);
      expect(run.runOpen).toBe(true);
    }
    // The run lines sit inside the fold: after the Worked for, and the replies keep their order.
    const worked = opened.findIndex((shown) => shown.kind === WORKED);
    expect(opened.findIndex((shown) => shown.id === "t-1")).toBeGreaterThan(worked);
    expect(opened.filter((shown) => REPLIES.includes(shown.id)).map((shown) => shown.id)).toEqual(REPLIES);
  });

test("a turn without a steer is unchanged: closed to its answer, opened to run lines that start closed", () => {
  for (const family of FAMILIES) {
    const closed = view(plain, family);
    expect(folds(closed).map((shown) => shown.kind)).toEqual([WORKED]);
    expect(closed.filter((shown) => shown.kind === "assistant").map((shown) => shown.id)).toEqual(["a-final"]);
    const opened = view(plain, family, true);
    for (const run of opened.filter((shown) => shown.kind === "activity")) expect(run.runOpen).toBeUndefined();
  }
});

// The run line as the transcript draws it: open from the first frame when its row says so.
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

async function render(shown: AcpmuxRow) {
  const { createRoot } = await import("react-dom/client");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  act(() => root?.unmount());
  root = createRoot(host);
  await act(async () => root!.render(<ToolRows row={shown} sessionId={`one-fold-${shown.id}-${shown.version}`} />));
}

test("opening a steered turn's Worked for shows its summary row expanded, every call in sight", async () => {
  const run = view(steered, "codex", true).find((shown) => shown.id === "t-1")!;
  await render(run);
  const line = host.querySelector<HTMLButtonElement>(".cv-tool.is-run")!;
  expect(line.textContent).toContain("Finished 2 background tasks");
  expect(line.getAttribute("aria-expanded")).toBe("true");
  // Every call of the run draws under its open line.
  expect(host.querySelectorAll(".cv-command").length).toBe(6);
});

test("a plain turn's opened run line starts closed, as before", async () => {
  const run = view(plain, "codex", true).find((shown) => shown.id === "t-1")!;
  await render(run);
  expect(host.querySelector(".cv-tool.is-run")!.getAttribute("aria-expanded")).toBe("false");
  expect(host.querySelectorAll(".cv-command").length).toBe(0);
});

// The estimate of an open run line is the rows it draws (review of cmux#37710): a run that keeps a
// coordination card (a message to another agent) and a change waiting for permission in sight draws,
// with `runOpen`, each stretch's line over its steps (ToolRunSteps.tsx, a line per call), as a run of
// plain work does. Every one of those rows is one 22px tool line (design/chat-transcript.md "One-line row pitch"), so the drawn
// height is the count of `.cv-tool` lines and sent-message rows (`.cv-sent-msg`, one each) times 22.
const LINE = 22;
const read = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "Read",
  tool: { id, title: "Read a", kind: "read", status: "completed", locations: [{ path: "/a/x.ts" }] },
});
const pendingEdit: AcpmuxActivity = {
  kind: "tool",
  text: "Edit",
  tool: {
    id: "p",
    title: "Edit x.ts",
    kind: "edit",
    status: "pending",
    locations: [{ path: "/a/x.ts" }],
    diffs: [{ path: "/a/x.ts", oldText: "a", newText: "b" }],
  },
};
const openRun = (id: string, items: AcpmuxActivity[]): AcpmuxRow =>
  row(id, "activity", 1, { settled: true, foldRun: true, runOpen: true, items });
const mixedOpen = openRun("mixed", [
  shell("a", "ls"),
  shell("b", "cat y"),
  shell("s", "acpmux send --no-wait lane-a 'Status?'"),
  shell("d", "git diff"),
  read("r"),
  pendingEdit,
  shell("e", "git status"),
  read("r2"),
]);

for (const [name, run, lines] of [
  // A line over its two commands, the sent message, a line over a command and a read, the pending
  // edit, and a line over a command and a read.
  ["a mixed stretch with a coordination card and a permission", mixedOpen, 11],
  // The summary over its four calls, one step each.
  ["a run of two groups", openRun("groups", [shell("a", "ls"), shell("b", "cat y"), read("r"), read("r2")]), 5],
  // One group: its line over its calls.
  ["a run of one group", openRun("one", [shell("a", "ls"), shell("b", "cat y")]), 3],
] as const)
  test(`an open run line's estimate is the rows it draws: ${name}`, async () => {
    await render(run);
    // A sent message is one row however it nests its line (AgentMessageRow.tsx: `.cv-tool` inside
    // `.cv-sent-msg`), so it counts once.
    const drawn = [...host.querySelectorAll(".cv-tool, .cv-sent-msg")].filter(
      (node) => !node.parentElement?.closest(".cv-sent-msg"),
    ).length;
    expect(drawn).toBe(lines);
    expect([...layoutConversation([run], 720).heights][0]).toBe(drawn * LINE);
  });

// The `header` arm's line names the work it holds, and the memoized row redraws when that changes
// (review of cmux#37710): a background build that ends late, or a call whose category comes in late,
// changes the line's text, so it changes the row's version too.
const toggle = () => {};
async function renderWorked(rows: readonly AcpmuxRow[]) {
  const { createRoot } = await import("react-dom/client");
  const { WorkedRow } = await import("../src/agent-session/acpmux/rows/WorkedRow");
  act(() => root?.unmount());
  root = createRoot(host);
  const label = () => host.querySelector(".cv-worked__label")!.textContent ?? "";
  const labels: string[] = [];
  for (const shown of rows) {
    await act(async () => root!.render(<WorkedRow row={shown} expanded={false} onToggleActivity={toggle} />));
    labels.push(label());
  }
  return labels;
}
const workedOf = (rows: AcpmuxRow[]) => {
  globalThis.cmuxExperiments = { "turn-fold-steered": "header" };
  return view(rows, "codex").find((shown) => shown.kind === WORKED)!;
};
const withRun = (id: string, run: AcpmuxRow) => steered.map((shown) => (shown.id === id ? run : shown));

test("the header arm's Worked for redraws when a background task ends late", async () => {
  const running = withRun(
    "t-1",
    row("t-1", "activity", 1, {
      items: (steered[1]!.items ?? []).map((item, index) =>
        index < 2 ? { ...item, tool: { ...item.tool!, background: { state: "running" as const } } } : item,
      ),
    }),
  );
  const before = workedOf(running);
  const after = workedOf(steered);
  expect(before.version).not.toBe(after.version);
  const [early, late] = await renderWorked([before, after]);
  expect(early).not.toContain("Finished 2 background tasks");
  expect(late).toContain("Finished 2 background tasks");
});

test("the header arm's Worked for redraws when a call's category changes", async () => {
  const asRead = withRun(
    "t-2",
    row("t-2", "activity", 131, {
      items: [shell("t-2-0", "gh run list"), { ...read("t-2-1"), tool: { ...read("t-2-1").tool!, id: "t-2-1" } }],
    }),
  );
  const before = workedOf(steered);
  const after = workedOf(asRead);
  expect(before.version).not.toBe(after.version);
  const [early, late] = await renderWorked([before, after]);
  expect(early).not.toBe(late);
  expect(late).toContain("read");
});
