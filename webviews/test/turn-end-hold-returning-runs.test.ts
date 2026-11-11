// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// The finished runs a running turn keeps out of sight stay out when they would come back between
// rows a reader scrolled up has in view (conversation/turnEndHold.ts `rowsToHold`). Under the
// shipped `line` look of live-turn-work a running turn draws its replies and one live line; when
// another agent's prompt opens a new turn over the stretch, turns.ts draws the stretch as it came,
// every run of it at once. agent-pane-turn-end-keeps-place.test.ts ("a turn that streams calls, a
// message and its end") measures the move in a browser; this file holds the rule.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { rowsToHold, withoutHeldRows } from "../src/agent-session/acpmux/conversation/turnEndHold";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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

test("the rows that are not held are the same objects, and no held row gives the same list", () => {
  expect(withoutHeldRows(split, new Set())).toBe(split);
  const kept = withoutHeldRows(split, new Set(["run2"]));
  expect(ids(kept)).toEqual(["u", "run1", "a1", "a2", "run3", "m"]);
  expect(kept[0]).toBe(split[0]);
  expect(kept[3]).toBe(split[4]);
});
