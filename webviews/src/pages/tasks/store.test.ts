import { describe, expect, test } from "bun:test";
import { MockTasksProvider } from "./mockProvider";
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
    newId: (prefix) => `${prefix}${key + 1}`,
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
    expect(id).toBe("task_1");
    expect(store.getSnapshot().selection).toBe(id);
    await tick();
    expect(provider.calls.at(-1)?.params).toMatchObject({ id, title: "Ship it" });
    expect(store.getSnapshot().mirror.tasks.get(id!)?.key).toBe("CMX-12");
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
