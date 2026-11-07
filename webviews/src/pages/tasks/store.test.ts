import { describe, expect, test } from "bun:test";
import { MockTasksProvider } from "./mockProvider";
import { statusGroups } from "./model";
import { TasksStore } from "./store";
import { TasksOps } from "./types";

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** The store's retry timers, run by hand. */
class Timers {
  queue: Array<() => void> = [];
  schedule = (run: () => void) => {
    this.queue.push(run);
    return () => {
      this.queue = this.queue.filter((entry) => entry !== run);
    };
  };
  /** Runs every due retry, then lets its read settle. */
  async fire() {
    const due = this.queue;
    this.queue = [];
    for (const run of due) run();
    await tick();
    await tick();
  }
}

async function started(provider = new MockTasksProvider(), visible = () => true) {
  let key = 0;
  const timers = new Timers();
  const store = new TasksStore(provider, {
    newKey: () => `k${++key}`,
    newId: (prefix) => `${prefix}new${key + 1}`,
    backoff: { initial: 1, maximum: 4 },
    schedule: timers.schedule,
    visible,
  });
  const stop = store.subscribe(() => {});
  await store.start();
  await tick();
  return { store, provider, stop, timers };
}

describe("TasksStore", () => {
  test("subscribes before it reads the snapshot, then is connected", async () => {
    const { store, provider, stop } = await started();
    expect(provider.calls[0]?.op).toBe(TasksOps.snapshot);
    expect(provider.subscriberCount).toBe(1);
    expect(store.getSnapshot().connection).toBe("connected");
    expect(store.getSnapshot().tasks.length).toBe(11);
    stop();
    expect(provider.subscriberCount).toBe(0);
  });

  test("an intent shows at once and stays until the mirror reaches its sequence", async () => {
    const provider = new MockTasksProvider();
    provider.echoAfterReply = true;
    const { store } = await started(provider);
    store.setStatus("task_5", "st_done");
    expect(store.getSnapshot().tasks.find((t) => t.id === "task_5")?.status).toBe("st_done");
    expect(store.isPending("task_5")).toBe(true);
    await tick();
    // The reply came first: still pending, still shown, no snap back.
    expect(store.isPending("task_5")).toBe(true);
    expect(store.getSnapshot().tasks.find((t) => t.id === "task_5")?.status).toBe("st_done");
    provider.flushEvents();
    expect(store.isPending("task_5")).toBe(false);
    expect(store.getSnapshot().mirror.tasks.get("task_5")?.status).toBe("st_done");
    const call = provider.calls.at(-1)!;
    expect(call.op).toBe(TasksOps.update);
    expect(call.params).toEqual({ task: "task_5", status: "st_done", idempotency_key: "k1" });
  });

  test("a refusal takes the intent back and shows the reason", async () => {
    const provider = new MockTasksProvider();
    provider.rejectKeys.add("k1");
    const { store } = await started(provider);
    store.archive("task_3");
    expect(store.getSnapshot().tasks.some((t) => t.id === "task_3")).toBe(false);
    await tick();
    expect(store.getSnapshot().tasks.some((t) => t.id === "task_3")).toBe(true);
    expect(store.getSnapshot().reject).toBe("rejected by the owner");
    expect(store.getSnapshot().pending).toEqual([]);
  });

  test("New Task selects the created task; an empty title sends nothing", async () => {
    const { store, provider } = await started();
    expect(store.createTask("   ")).toBeUndefined();
    const id = store.createTask(" Ship it ");
    expect(id).toBe("task_new1");
    expect(store.getSnapshot().selection).toBe(id);
    await tick();
    expect(provider.calls.at(-1)?.params).toMatchObject({ id, title: "Ship it" });
    expect(store.getSnapshot().mirror.tasks.get(id!)?.key).toBe("CMX-12");
  });

  test("a create that times out stays unsent, off the rows, and is never sent again on its own", async () => {
    const { store, provider, timers } = await started();
    provider.failNext.push({ code: "cmux.operation.failed", owner: "tasks.timeout" });
    const id = store.createTask("Ship it")!;
    await tick();
    expect(store.createOutcome(id)).toEqual({ state: "unsent", key: "k1" });
    expect(store.getSnapshot().reject).toBeUndefined();
    // Its text is in the New Task field (with Retry), not a row.
    expect(store.getSnapshot().tasks.some((t) => t.id === id)).toBe(false);
    await timers.fire();
    expect(provider.calls.filter((call) => call.op === TasksOps.create).length).toBe(1);
  });

  test("a page-side timeout on a status change leaves the row's change unsent", async () => {
    const { store, provider } = await started();
    provider.failNext.push({ code: "cmux.protocol.timeout" });
    store.setStatus("task_5", "st_done");
    await tick();
    expect(store.unsent("task_5")?.kind).toEqual({ type: "setStatus", task: "task_5", status: "st_done" });
    // Not drawn: the row keeps its confirmed status until the change settles.
    expect(store.getSnapshot().tasks.find((t) => t.id === "task_5")?.status).not.toBe("st_done");
  });

  test("a create that committed before the link broke settles on reconnect, with no second create", async () => {
    const { store, provider } = await started();
    provider.failNext.push({ code: "cmux.operation.failed", owner: "tasks.owner_unreachable", commit: true });
    const id = store.createTask("Ship it")!;
    await tick();
    // The lost link reads the snapshot again at once; the task is there, so the create settles.
    await tick();
    expect(store.getSnapshot().connection).toBe("connected");
    expect(store.createOutcome(id).state).toBe("done");
    expect(store.getSnapshot().pending).toEqual([]);
    expect(provider.calls.filter((call) => call.op === TasksOps.create).length).toBe(1);
    expect(provider.state.tasks.filter((t) => t.title === "Ship it").length).toBe(1);
  });

  test("Retry sends the unsent change again with its original key", async () => {
    const { store, provider } = await started();
    // A timeout that never committed (a commit would settle on the read the timeout starts).
    provider.failNext.push({ code: "cmux.operation.failed", owner: "tasks.timeout" });
    const id = store.createTask("Ship it")!;
    await tick();
    expect(store.retry("k1")).toBe(true);
    await tick();
    const creates = provider.calls.filter((call) => call.op === TasksOps.create);
    expect(creates.map((call) => call.params.idempotency_key)).toEqual(["k1", "k1"]);
    expect(provider.state.tasks.filter((t) => t.title === "Ship it").length).toBe(1);
    expect(store.createOutcome(id).state).toBe("done");
  });

  test("a gesture refusal on Retry keeps the change unsent and says why", async () => {
    const { store, provider } = await started();
    // The page relay's code for a call no gesture backs.
    provider.failNext.push({ code: "cmux.protocol.closed" }, { code: "cmux.origin.forbidden" });
    store.archive("task_3");
    await tick();
    expect(store.unsent("task_3")?.key).toBe("k1");
    // The link came back; the person's Retry is refused for want of a gesture.
    await store.start();
    await tick();
    expect(store.retry("k1")).toBe(true);
    await tick();
    expect(store.unsent("task_3")?.key).toBe("k1");
    expect(store.getSnapshot().reject).toBe("no answer");
    store.discard("k1");
    expect(store.unsent("task_3")).toBeUndefined();
    expect(store.getSnapshot().tasks.some((t) => t.id === "task_3")).toBe(true);
  });

  test("an unsent archive is listed as unsent and its row stays in the list", async () => {
    const { store, provider } = await started();
    provider.failNext.push({ code: "cmux.protocol.timeout" });
    store.archive("task_3");
    await tick();
    expect(store.unsentAll().map((intent) => intent.kind)).toEqual([{ type: "archive", task: "task_3" }]);
    const { shown, mirror } = store.getSnapshot();
    expect(shown.some((t) => t.id === "task_3")).toBe(true);
    const groups = statusGroups(mirror.statuses, shown);
    expect(groups.some((group) => group.tasks.some((t) => t.id === "task_3"))).toBe(true);
  });

  test("an unsent cancel keeps its card in its board column", async () => {
    const { store, provider } = await started();
    const before = store.getSnapshot().mirror.tasks.get("task_5")!.status;
    provider.failNext.push({ code: "cmux.operation.failed", owner: "tasks.owner_unreachable" });
    store.setStatus("task_5", "st_canceled");
    await tick();
    await tick();
    expect(store.unsent("task_5")?.kind).toEqual({ type: "setStatus", task: "task_5", status: "st_canceled" });
    const { shown, mirror } = store.getSnapshot();
    const column = statusGroups(mirror.statuses, shown).find((group) => group.status.id === before)!;
    expect(column.tasks.some((t) => t.id === "task_5")).toBe(true);
  });

  test("a change made elsewhere arrives as an event and keeps the selection", async () => {
    const { store, provider } = await started();
    store.select("task_2");
    const task = { ...provider.state.tasks[0]!, title: "From the CLI" };
    provider.publish({
      change: {
        seq: 43,
        tx: "cli",
        kind: "task.updated",
        change: { type: "upsert", value: { entity: "task", ...task } },
      },
    });
    expect(store.getSnapshot().tasks.find((t) => t.id === task.id)?.title).toBe("From the CLI");
    expect(store.getSnapshot().selection).toBe("task_2");
  });

  test("a create whose echo came before its reply timed out settles; New Task is free again", async () => {
    const { store, provider } = await started();
    provider.failNext.push({ code: "cmux.protocol.timeout", commit: true, echo: true });
    const id = store.createTask("Ship it")!;
    await tick();
    expect(store.createOutcome(id).state).toBe("done");
    expect(store.unsentAll()).toEqual([]);
    expect(provider.calls.filter((call) => call.op === TasksOps.create).length).toBe(1);
  });

  test("a status change that timed out after it committed settles on the snapshot read", async () => {
    const { store, provider } = await started();
    provider.failNext.push({ code: "cmux.operation.failed", owner: "tasks.timeout", commit: true });
    store.setStatus("task_5", "st_done");
    await tick();
    await tick();
    expect(store.unsent("task_5")).toBeUndefined();
    expect(store.getSnapshot().mirror.tasks.get("task_5")?.status).toBe("st_done");
  });

  test("a snapshot read that times out is retried on the backoff", async () => {
    const provider = new MockTasksProvider();
    provider.failSnapshots.push(
      { code: "cmux.protocol.timeout" },
      { code: "cmux.operation.failed", owner: "tasks.timeout" },
    );
    const { store, timers } = await started(provider);
    expect(store.getSnapshot().connection).toBe("unreachable");
    expect(timers.queue.length).toBe(1);
    await timers.fire();
    expect(timers.queue.length).toBe(1);
    await timers.fire();
    expect(store.getSnapshot().connection).toBe("connected");
  });

  test("no owner: unreachable, retried on a backoff until it answers", async () => {
    const provider = new MockTasksProvider();
    provider.ownerDown = true;
    const { store, stop, timers } = await started(provider);
    expect(store.getSnapshot().connection).toBe("unreachable");
    expect(store.getSnapshot().everConnected).toBe(false);
    expect(store.send({ type: "archive", task: "task_1" })).toBe(false);
    await timers.fire();
    expect(store.getSnapshot().connection).toBe("unreachable");
    expect(timers.queue.length).toBe(1);
    provider.ownerDown = false;
    await timers.fire();
    expect(store.getSnapshot().connection).toBe("connected");
    expect(timers.queue.length).toBe(0);
    stop();
  });

  test("the retry stops while the page is hidden", async () => {
    const provider = new MockTasksProvider();
    provider.ownerDown = true;
    let visible = false;
    const { store, stop, timers } = await started(provider, () => visible);
    const calls = provider.calls.length;
    expect(timers.queue.length).toBe(0);
    await timers.fire();
    expect(provider.calls.length).toBe(calls);
    expect(store.getSnapshot().connection).toBe("unreachable");
    visible = true;
    stop();
  });

  test("a lost owner link keeps the rows, refuses changes, and reads again", async () => {
    const { store, provider, timers } = await started();
    provider.loseOwner();
    expect(store.getSnapshot().connection).toBe("unreachable");
    expect(store.getSnapshot().tasks.length).toBe(11);
    expect(store.getSnapshot().everConnected).toBe(true);
    // The re-read the loss starts fails while the owner is down, and schedules a retry.
    await tick();
    expect(timers.queue.length).toBe(1);
    provider.ownerDown = false;
    await timers.fire();
    expect(store.getSnapshot().connection).toBe("connected");
  });

  test("events during the snapshot read apply on top of it", async () => {
    const provider = new MockTasksProvider();
    const store = new TasksStore(provider, { visible: () => true });
    const original = provider.call.bind(provider);
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      const value = await original<R>(op, params);
      if (op === TasksOps.snapshot) {
        const task = { ...provider.state.tasks[1]!, title: "During the read" };
        provider.publish({
          change: {
            seq: 43,
            tx: "x",
            kind: "task.updated",
            change: { type: "upsert", value: { entity: "task", ...task } },
          },
        });
      }
      return value;
    };
    store.subscribe(() => {});
    await store.start();
    await tick();
    expect(store.getSnapshot().tasks.find((t) => t.id === "task_2")?.title).toBe("During the read");
  });

  test("a resync from the relay reads the snapshot again and keeps the rows", async () => {
    const { store, provider } = await started();
    const task = { ...provider.state.tasks[0]!, title: "Changed while events were lost" };
    provider.state.tasks[0] = task;
    provider.state.seq += 1;
    const reads = provider.calls.filter((call) => call.op === TasksOps.snapshot).length;
    provider.publish({ resync: true });
    expect(store.getSnapshot().tasks.length).toBe(11);
    await tick();
    expect(provider.calls.filter((call) => call.op === TasksOps.snapshot).length).toBe(reads + 1);
    expect(store.getSnapshot().tasks.find((t) => t.id === task.id)?.title).toBe("Changed while events were lost");
    expect(store.getSnapshot().connection).toBe("connected");
  });

  test("a failed event subscribe is unreachable and retried until the relay answers", async () => {
    const provider = new MockTasksProvider();
    provider.failSubscribes = 2;
    const { store, timers, stop } = await started(provider);
    expect(store.getSnapshot().connection).toBe("unreachable");
    expect(provider.subscriberCount).toBe(0);
    expect(timers.queue.length).toBe(1);
    await timers.fire();
    expect(store.getSnapshot().connection).toBe("unreachable");
    await timers.fire();
    expect(provider.subscriberCount).toBe(1);
    expect(store.getSnapshot().connection).toBe("connected");
    stop();
  });

  test("a connection change during a subscribe makes no second subscription", async () => {
    const provider = new MockTasksProvider();
    provider.failSubscribes = 1;
    const { store, timers } = await started(provider);
    expect(store.getSnapshot().connection).toBe("unreachable");
    // The retry and a reconnect start together; only one subscribes.
    const pending = timers.fire();
    provider.setHostConnected(false);
    provider.setHostConnected(true);
    await pending;
    await tick();
    expect(provider.subscriberCount).toBe(1);
    expect(store.getSnapshot().connection).toBe("connected");
  });

  test("a second start waits for the one in flight", async () => {
    const provider = new MockTasksProvider();
    const store = new TasksStore(provider, { visible: () => true });
    store.subscribe(() => {});
    await store.start();
    expect(store.getSnapshot().connection).toBe("connected");
    expect(provider.subscriberCount).toBe(1);
  });

  test("assignee choices send update or delegate", async () => {
    const { store, provider } = await started();
    expect(store.choose("task_5", { type: "person", id: "usr_austin" })).toBe(true);
    await tick();
    expect(provider.calls.at(-1)).toMatchObject({
      op: TasksOps.update,
      params: { task: "task_5", assignee: "usr_austin" },
    });
    expect(store.choose("task_5", { type: "agent", harness: "codex" })).toBe(true);
    await tick();
    expect(provider.calls.at(-1)).toMatchObject({
      op: TasksOps.delegate,
      params: { task: "task_5", harness: "codex" },
    });
    expect(store.getSnapshot().mirror.tasks.get("task_5")?.delegate?.harness).toBe("codex");
  });
});
