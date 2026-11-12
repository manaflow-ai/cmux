// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// The finished runs a running turn keeps out of sight stay out when they would come back between
// rows a reader scrolled up has in view (conversation/turnEndHold.ts `rowsToHold`). Under the
// retained `line` look of live-turn-work a running turn draws its replies and one live line; when
// another agent's prompt opens a new turn over the stretch, turns.ts draws the stretch as it came,
// every run of it at once. agent-pane-turn-end-keeps-place.test.ts ("a turn that streams calls, a
// message and its end") measures the move in a browser; this file holds the rule.
import { afterAll, beforeAll, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { rowsToHold, withoutHeldRows } from "../src/agent-session/acpmux/conversation/turnEndHold";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const armsBefore = globalThis.cmuxExperiments;
beforeAll(() => {
  globalThis.cmuxExperiments = { ...armsBefore, "live-turn-work": "line", "live-turn-clock": "line" };
});
afterAll(() => {
  if (armsBefore === undefined) delete globalThis.cmuxExperiments;
  else globalThis.cmuxExperiments = armsBefore;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, status = "completed", kind = "execute"): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind, status, command: id, startedAt: at },
});
const live = (rows: readonly AcpmuxRow[]) => turnView(rows, new Set(), { working: true });
const ids = (rows: readonly AcpmuxRow[]) => rows.filter((each) => each.kind !== "date").map((each) => each.id);
const runs = (rows: readonly AcpmuxRow[]) => ids(rows.filter((each) => each.kind === "activity"));

const stretch: AcpmuxRow[] = [
  row("u", "user", { text: "Fix the flaky test" }),
  row("run1", "activity", { items: [call("rg retry"), call("git log")] }),
  row("a1", "assistant", { text: "The backoff is scheduled twice." }),
  row("run2", "activity", { items: [call("bun test src/net"), call("git diff")] }),
  row("a2", "assistant", { text: "One more call site." }),
  row("run3", "activity", { items: [call("rg backoff"), call("bun test")] }),
];
// Another agent's message that arrives while the turn runs: a prompt, not a steer.
const message = row("m", "user", { text: "One more retry loop in the queue." });
const split = [...stretch, message];

test("the look this file is about: a running turn draws no finished run, and a prompt over it draws them all", () => {
  expect(runs(live(stretch))).toEqual([]);
  expect(runs(live(split))).toEqual(["run1", "run2", "run3"]);
});

test("runs that come back between rows in view are all held, and the stretch reads as the reader saw it", () => {
  const before = live(stretch);
  const held = rowsToHold(split, live(split), before, undefined, ["a1", "a2"]);
  expect([...held].sort()).toEqual(["run1", "run2", "run3"]);
  const kept = live(withoutHeldRows(split, new Set(held)));
  expect(runs(kept)).toEqual([]);
  // The rows the reader had in view keep their order, with nothing between them.
  const shown = ids(kept);
  expect(shown.slice(0, shown.indexOf("a2") + 1)).toEqual(ids(before).slice(0, ids(before).indexOf("a2") + 1));
  expect(shown).toContain("m");
});

test("the prompt and the first reply in view hold them too: a run comes back between the two", () => {
  expect(rowsToHold(split, live(split), live(stretch), undefined, ["u", "a1"]).length).toBe(3);
  // The same with the prompt in the rows the update did not reshape.
  expect(rowsToHold(split, live(split), live(stretch), 1, ["u", "a1"]).length).toBe(3);
});

test("a reader with no row in view on both sides of a run holds nothing", () => {
  const hold = (inView: string[]) => rowsToHold(split, live(split), live(stretch), undefined, inView);
  // Over every run: they come back under the view.
  expect(hold(["u"])).toEqual([]);
  // Under every run that a row of the chat follows: the last run, the footer and the prompt are the
  // new rows of the chat's end, which come in under the last reply as any new row does.
  expect(hold(["a2", "thinking-live"])).toEqual([]);
  expect(hold([])).toEqual([]);
});

test("a new run at the chat's end is not a run that comes back", () => {
  const before = [stretch[0]!, stretch[2]!, row("thinking-live", "thinking")];
  const next = row("run9", "activity", { items: [call("git status")] });
  const drawn = [stretch[0]!, stretch[2]!, next, row("thinking-live", "thinking")];
  expect(rowsToHold([stretch[0]!, stretch[2]!, next], drawn, before, undefined, ["a1", "thinking-live"])).toEqual([]);
});

test("a run with a call that still runs is never held", () => {
  const running = stretch.map((each) =>
    each.id === "run2" ? { ...each, items: [call("bun test src/net"), call("sleep 600", "in_progress")] } : each,
  );
  const over = [...running, message];
  // Its call is the live line's while the turn runs, and its row draws when the stretch ends.
  expect(runs(live(running))).toEqual([]);
  expect(runs(live(over))).toContain("run2");
  const held = rowsToHold(over, live(over), live(running), undefined, ["u", "a1", "a2"]);
  expect([...held].sort()).toEqual(["run1", "run3"]);
});

test("the edits card of the stretch is held by every edit row it merged", () => {
  const edit = (id: string) => row(id, "activity", { items: [call(id, "completed", "edit")] });
  const edited = [...stretch.slice(0, 3), edit("e1"), ...stretch.slice(3), edit("e2")];
  const over = [...edited, message];
  expect(runs(live(edited))).toEqual([]);
  const held = rowsToHold(over, live(over), live(edited), undefined, ["a1", "a2"]);
  expect(held).toEqual(expect.arrayContaining(["e1", "e2", "run1", "run2", "run3"]));
  expect(runs(live(withoutHeldRows(over, new Set(held))))).toEqual([]);
});

test("an id in view that is no row of the turns says nothing about where the reader is", () => {
  // A card the view makes after the turns (received messages, a shell) is in view under every run.
  const hold = (reused: number | undefined, inView: string[]) =>
    rowsToHold(split, live(split), live(stretch), reused, inView);
  expect(hold(undefined, ["received:m", "thinking-live"])).toEqual([]);
  expect(hold(1, ["shell-1", "thinking-live"])).toEqual([]);
  // With a row of the chat under a run too, nothing in view is over one.
  expect(hold(undefined, ["received:m", "a2"])).toEqual([]);
});

test("an older page that loads over the view holds none of its runs", () => {
  // The page comes in at the chat's start, so no row of the view before is reused. Its runs are
  // over every row the reader reads: nothing in view moves between two rows. The app shapes the
  // rows without the runs it holds already, before and after.
  const older = [
    row("u0", "user", { text: "Read the log" }),
    row("run0", "activity", { items: [call("tail log")] }),
    row("a0", "assistant", { text: "Two retries failed." }),
  ];
  const paged = [...older, ...split];
  const held = new Set(["run1", "run2", "run3"]);
  // One date over the chat, with the same id before and after the page: the view's row, in view.
  const day = row("day", "date");
  const shaped = (rows: readonly AcpmuxRow[]) => [
    day,
    ...live(withoutHeldRows(rows, held)).filter((each) => each.kind !== "date"),
  ];
  expect(runs(shaped(paged))).toEqual(["run0"]);
  const hold = (inView: string[]) => rowsToHold(paged, shaped(paged), shaped(split), 0, inView);
  expect(hold(["received:m", "a1", "a2"])).toEqual([]);
  expect(hold(["day", "u", "a1"])).toEqual([]);
});

test("a new run with the todo list under it is not a run that comes back", () => {
  // The view puts the list under the work, whatever its place in the chat (the `runs` look).
  const plan = row("plan", "plan");
  const next = row("run9", "activity", { items: [call("git status")] });
  const before = [stretch[0]!, stretch[2]!, plan, row("thinking-live", "thinking")];
  const drawn = [stretch[0]!, stretch[2]!, next, plan, row("thinking-live", "thinking")];
  const inView = ["u", "a1", "plan", "thinking-live"];
  expect(rowsToHold([stretch[0]!, plan, stretch[2]!, next], drawn, before, undefined, inView)).toEqual([]);
  expect(rowsToHold([stretch[0]!, stretch[2]!, next, plan], drawn, before, undefined, inView)).toEqual([]);
});

test("a run with a short note joined in is held by each of its runs, and the note stays", () => {
  const note = row("n", "assistant", { text: "Now the queue." });
  const chat = [stretch[0]!, stretch[1]!, note, stretch[3]!, stretch[4]!, message];
  const before = [stretch[0]!, note, stretch[4]!, row("thinking-live", "thinking")];
  const joined = { ...stretch[1]!, joined: ["run1", "n", "run2"] };
  const drawn = [stretch[0]!, joined, stretch[4]!, message, row("thinking-live", "thinking")];
  const held = rowsToHold(chat, drawn, before, undefined, ["u", "n", "a2"]);
  expect([...held].sort()).toEqual(["run1", "run2"]);
  expect(ids(withoutHeldRows(chat, new Set(held)))).toEqual(["u", "n", "a2", "m"]);
});

test("the rows that are not held are the same objects, and no held row gives the same list", () => {
  expect(withoutHeldRows(split, new Set())).toBe(split);
  const held = new Set(["run2"]);
  const kept = withoutHeldRows(split, held);
  expect(ids(kept)).toEqual(["u", "run1", "a1", "a2", "run3", "m"]);
  expect(kept[0]).toBe(split[0]);
  expect(kept[3]).toBe(split[4]);
  // The same rows and the same held set give the same list, so turns.ts sees no change.
  expect(withoutHeldRows(split, held)).toBe(kept);
});

test("a held run whose call runs again, or waits for the reader, is drawn", () => {
  const again = split.map((each) =>
    each.id === "run2" ? { ...each, items: [...(each.items ?? []), call("gh pr merge", "pending")] } : each,
  );
  expect(ids(withoutHeldRows(again, new Set(["run1", "run2", "run3"])))).toEqual(["u", "a1", "run2", "a2", "m"]);
});
