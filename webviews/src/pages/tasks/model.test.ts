import { describe, expect, test } from "bun:test";
import {
  applyEvent,
  assigneeChoices,
  choiceIntent,
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

describe("route", () => {
  test("scope and the New Task token", () => {
    expect(parseRoute("#/mine?new=3")).toEqual({ scope: "mine", newTask: "3" });
    expect(parseRoute("#/all")).toEqual({ scope: "all" });
    expect(parseRoute("")).toEqual({});
    expect(parseLayout("board")).toBe("board");
    expect(parseLayout(undefined)).toBe("inbox");
  });
});
