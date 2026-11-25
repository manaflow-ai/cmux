// l10n-allow-file: test fixture task steps, not shipped UI.
import { describe, expect, test } from "bun:test";
import { chatTaskListOf, hasStepsLeft, hatPlanOf } from "../src/agent-session/acpmux/chatTaskList";

// The chat's task list across its turns (acpmux `taskList`): the composer's hat shows it between
// turns, and while a turn runs without a list of its own (David Beyer, Nov 20 call).
const wire = {
  source: "harness",
  done: 1,
  total: 3,
  current: "Fix the queue",
  next: "Land",
  updatedAt: 1_000,
  items: [
    { content: "Read the brief", status: "completed" },
    { content: "Fix the queue", status: "in_progress" },
    { content: "Land", status: "pending" },
  ],
};

describe("chatTaskListOf", () => {
  test("reads the summary's list and keeps its object while it is the same", () => {
    const list = chatTaskListOf(wire);
    expect(list).toEqual({ source: "harness", done: 1, total: 3, items: wire.items as never, updatedAt: 1_000 });
    expect(chatTaskListOf({ ...wire }, list)).toBe(list!);
    const ticked = chatTaskListOf(
      { ...wire, updatedAt: 2_000, items: wire.items.map((i) => ({ ...i, status: "completed" })) },
      list,
    );
    expect(ticked).not.toBe(list!);
    expect(ticked?.done).toBe(3);
    expect(hasStepsLeft(ticked)).toBe(false);
  });

  test("a row with only its counts, null, or junk is no list", () => {
    expect(chatTaskListOf({ source: "chief", done: 1, total: 2 })).toBeUndefined();
    expect(chatTaskListOf(null)).toBeUndefined();
    expect(chatTaskListOf([])).toBeUndefined();
    expect(chatTaskListOf({ items: [{ content: " ", status: "pending" }] })).toBeUndefined();
    expect(chatTaskListOf({ items: [{ content: "x", status: "odd" }] })?.items).toEqual([
      { content: "x", status: "pending" },
    ]);
  });
});

describe("hatPlanOf", () => {
  const list = chatTaskListOf(wire)!;
  const chief = chatTaskListOf({ ...wire, source: "chief" })!;
  const live = [{ content: "Live step", status: "in_progress" as const }];
  const earlier = [{ content: "Earlier step", status: "pending" as const }];

  test("a running turn's own list leads", () => {
    expect(hatPlanOf({ working: true, live, earlier, list })).toEqual({ plan: live, earlier: false, kept: false });
  });

  test("a running turn without one shows the earlier list, else the chat's when that row paged out", () => {
    expect(hatPlanOf({ working: true, earlier, list })).toEqual({ plan: earlier, earlier: true, kept: false });
    expect(hatPlanOf({ working: true, list })).toEqual({ plan: list.items, earlier: true, kept: false });
  });

  test("a list the Chief keeps is the chat's current one, never an earlier turn's", () => {
    expect(hatPlanOf({ working: true, earlier, list: chief })).toEqual({
      plan: chief.items,
      earlier: false,
      kept: false,
    });
  });

  test("between turns the chat's list shows while steps are left, and not once it is done", () => {
    expect(hatPlanOf({ working: false, live, list })).toEqual({ plan: list.items, earlier: false, kept: true });
    const done = chatTaskListOf({ ...wire, items: wire.items.map((i) => ({ ...i, status: "completed" })) });
    expect(hatPlanOf({ working: false, list: done })).toBeUndefined();
    expect(hatPlanOf({ working: false })).toBeUndefined();
  });
});
