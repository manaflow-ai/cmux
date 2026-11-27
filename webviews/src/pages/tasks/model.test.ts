import { describe, expect, test } from "bun:test";
import {
  applyEvent,
  assigneeChoices,
  choiceIntent,
  committedIn,
  fromSnapshot,
  inboxGroups,
  intentWire,
  isCurrentChoice,
  scoped,
  sessionFor,
  statusGroups,
  visibleTasks,
  type Intent,
} from "./model";
import { sampleSnapshot } from "./mockProvider";
import { parseLayout, parseRoute } from "./route";

const mirror = () => fromSnapshot(sampleSnapshot());
const intent = (kind: Intent["kind"], key = "k"): Intent => ({ key, kind });

describe("mirror", () => {
  test("a snapshot fills keys and categories and orders statuses by workflow", () => {
    const m = mirror();
    expect(m.seq).toBe(42);
    expect(m.tasks.get("task_3")?.key).toBe("CMX-3");
    expect(m.tasks.get("task_3")?.category).toBe("unstarted");
    expect(m.statuses.map((s) => s.id)).toEqual([
      "st_triage",
      "st_backlog",
      "st_todo",
      "st_in_progress",
      "st_in_review",
      "st_done",
      "st_canceled",
    ]);
  });

  test("an event at or below the snapshot is already in it; a later one upserts", () => {
    const m = mirror();
    const task = { ...m.tasks.get("task_1")!, title: "renamed" };
    const stale = applyEvent(m, {
      seq: 42,
      tx: "x",
      kind: "task.updated",
      change: { type: "upsert", value: { entity: "task", ...task } },
    });
    expect(stale).toBe(m);
    const next = applyEvent(m, {
      seq: 43,
      tx: "x",
      kind: "task.updated",
      change: { type: "upsert", value: { entity: "task", ...task } },
    });
    expect(next.tasks.get("task_1")?.title).toBe("renamed");
    expect(next.tasks.get("task_1")?.key).toBe("CMX-1");
    expect(next.seq).toBe(43);
    expect(m.tasks.get("task_1")?.title).not.toBe("renamed");
  });

  test("a settings event with a new key prefix renames every key", () => {
    const m = mirror();
    const next = applyEvent(m, {
      seq: 43,
      tx: "s",
      kind: "settings",
      change: { type: "upsert", value: { entity: "settings", ...m.settings, key_prefix: "OPS" } },
    });
    expect(next.tasks.get("task_3")?.key).toBe("OPS-3");
    expect(m.tasks.get("task_3")?.key).toBe("CMX-3");
  });

  test("a decimal sequence sent as a string still orders", () => {
    const m = fromSnapshot({ ...sampleSnapshot(), seq: "7" as unknown as number });
    expect(m.seq).toBe(7);
  });

  test("an archived label leaves the mirror; a status removal drops it", () => {
    let m = mirror();
    m = applyEvent(m, {
      seq: 43,
      tx: "a",
      kind: "label",
      change: { type: "upsert", value: { entity: "label", id: "lbl_bug", name: "bug", color: 1, archived: true } },
    });
    expect(m.labels.has("lbl_bug")).toBe(false);
    m = applyEvent(m, {
      seq: 44,
      tx: "b",
      kind: "status",
      change: { type: "remove", entity: "status", id: "st_triage" },
    });
    expect(m.statuses.some((s) => s.id === "st_triage")).toBe(false);
  });
});

describe("pending intents", () => {
  test("status, archive, assign and create show before their echo", () => {
    const m = mirror();
    const tasks = visibleTasks(m, [
      intent({ type: "setStatus", task: "task_5", status: "st_done" }),
      intent({ type: "archive", task: "task_6" }),
      intent({ type: "assign", task: "task_3", person: "usr_lawrence" }),
      intent({ type: "create", id: "task_new", title: "Fresh" }),
    ]);
    const byId = new Map(tasks.map((t) => [t.id, t]));
    expect(byId.get("task_5")?.status).toBe("st_done");
    expect(byId.get("task_5")?.category).toBe("completed");
    expect(byId.has("task_6")).toBe(false);
    expect(byId.get("task_3")?.assignee?.id).toBe("usr_lawrence");
    const created = byId.get("task_new")!;
    expect(created.key).toBe("CMX-12");
    expect(created.status).toBe("st_backlog");
    expect(tasks.at(-1)?.id).toBe("task_new");
  });

  test("successive pending creates take successive keys", () => {
    const m = mirror();
    const keys = visibleTasks(m, [
      intent({ type: "create", id: "task_a", title: "A" }, "k1"),
      intent({ type: "create", id: "task_b", title: "B" }, "k2"),
    ])
      .filter((t) => t.id === "task_a" || t.id === "task_b")
      .map((t) => t.key);
    expect(keys).toEqual(["CMX-12", "CMX-13"]);
  });

  test("a move places the task between its neighbours", () => {
    const m = mirror();
    const order = visibleTasks(m, [intent({ type: "move", task: "task_9", after: "task_1" })]).map((t) => t.id);
    expect(order.slice(0, 3)).toEqual(["task_1", "task_9", "task_2"]);
  });

  test("a delegation names the local person's agent and keeps the assignee", () => {
    const m = mirror();
    const task = visibleTasks(m, [
      intent({ type: "delegate", task: "task_5", session: "asess_x", harness: "claude" }),
    ]).find((t) => t.id === "task_5")!;
    expect(task.delegate?.principal).toBe("agt_claude-lawrence");
    expect(task.assignee?.id).toBe("usr_lawrence");
  });

  test("wire ops", () => {
    expect(intentWire({ type: "assign", task: "t" })).toEqual({
      verb: "update",
      params: { task: "t", unassign: true },
    });
    expect(intentWire({ type: "setStatus", task: "t", status: "s" })).toEqual({
      verb: "update",
      params: { task: "t", status: "s" },
    });
    expect(intentWire({ type: "move", task: "t", before: "b" })).toEqual({
      verb: "move",
      params: { task: "t", before: "b" },
    });
  });
});

describe("layouts", () => {
  test("list and board groups leave canceled out and keep every status", () => {
    const m = mirror();
    const groups = statusGroups(m.statuses, visibleTasks(m, []));
    expect(groups.map((g) => g.status.id)).not.toContain("st_canceled");
    expect(groups.reduce((sum, g) => sum + g.tasks.length, 0)).toBe(11);
  });

  test("the inbox puts attention first and every open task in one group", () => {
    const m = mirror();
    const groups = inboxGroups(visibleTasks(m, []), m.me);
    const ids = Object.fromEntries(groups.map((g) => [g.id, g.tasks.map((t) => t.id)]));
    expect(ids.needsInput).toEqual(["task_1"]);
    expect(ids.review).toEqual(["task_2"]);
    expect(ids.failed).toEqual(["task_8"]);
    expect(ids.mine).toEqual(["task_4", "task_11"]);
    // Done (task_9) is not open.
    const all = groups.flatMap((g) => g.tasks.map((t) => t.id));
    expect(all).not.toContain("task_9");
    expect(new Set(all).size).toBe(all.length);
  });

  test("My Tasks narrows to the local person", () => {
    const m = mirror();
    const mine = scoped(visibleTasks(m, []), "mine", m.me);
    expect(mine.every((t) => t.assignee?.id === "usr_lawrence")).toBe(true);
    expect(scoped(visibleTasks(m, []), "mine", undefined)).toEqual([]);
  });

  test("the session is the active one, else the latest", () => {
    const m = mirror();
    expect(sessionFor(m, "task_1")?.id).toBe("asess_1");
    expect(sessionFor(m, "task_3")).toBeUndefined();
  });
});

describe("assignee", () => {
  test("people first, then agents the app knows and any the mirror names", () => {
    const m = mirror();
    const choices = assigneeChoices(m, visibleTasks(m, []));
    expect(choices.people).toEqual(["usr_lawrence", "usr_austin"]);
    expect(choices.agents).toEqual(["claude", "codex", "opencode"]);
  });

  test("a choice the task already has sends nothing; an agent with a live session is current", () => {
    const m = mirror();
    const task1 = m.tasks.get("task_1")!;
    expect(choiceIntent(m, task1, { type: "person", id: "usr_lawrence" }, () => "s")).toBeUndefined();
    expect(choiceIntent(m, task1, { type: "agent", harness: "claude" }, () => "s")).toBeUndefined();
    expect(choiceIntent(m, task1, { type: "agent", harness: "codex" }, () => "asess_n")).toEqual({
      type: "delegate",
      task: "task_1",
      session: "asess_n",
      harness: "codex",
    });
    expect(isCurrentChoice(m, task1, { type: "agent", harness: "claude" })).toBe(true);
    const task5 = m.tasks.get("task_5")!;
    expect(choiceIntent(m, task5, { type: "nobody" }, () => "s")).toBeUndefined();
    expect(isCurrentChoice(m, task5, { type: "nobody" })).toBe(true);
  });
});

describe("unsent intents", () => {
  test("committedIn tells a change already in the mirror; a move never", () => {
    const m = mirror();
    const task5 = m.tasks.get("task_5")!;
    expect(committedIn(m, { type: "create", id: "task_1", title: "x" })).toBe(true);
    expect(committedIn(m, { type: "create", id: "task_new", title: "x" })).toBe(false);
    expect(committedIn(m, { type: "setStatus", task: "task_5", status: task5.status })).toBe(true);
    expect(committedIn(m, { type: "setStatus", task: "task_5", status: "st_other" })).toBe(false);
    expect(committedIn(m, { type: "archive", task: "task_gone" })).toBe(true);
    expect(committedIn(m, { type: "archive", task: "task_5" })).toBe(false);
    expect(committedIn(m, { type: "assign", task: "task_5" })).toBe(true);
    expect(committedIn(m, { type: "move", task: "task_5" })).toBe(false);
  });

  test("unsent changes are not drawn: no row for a create, and an archived row stays", () => {
    const m = mirror();
    const pending: Intent[] = [
      { key: "a", kind: { type: "create", id: "task_new", title: "Draft" }, unsent: true },
      { key: "b", kind: { type: "archive", task: "task_5" }, unsent: true },
    ];
    const tasks = visibleTasks(m, pending);
    expect(tasks.some((t) => t.id === "task_new")).toBe(false);
    expect(tasks.some((t) => t.id === "task_5")).toBe(true);
  });
});

describe("route", () => {
  test("scope and the New Task token", () => {
    expect(parseRoute("#/mine?new=3")).toEqual({ scope: "mine", newTask: "3" });
    expect(parseRoute("#/all")).toEqual({ scope: "all" });
    expect(parseRoute("")).toEqual({});
    expect(parseLayout("board")).toBe("board");
    expect(parseLayout(undefined)).toBe("inbox");
  });
});
