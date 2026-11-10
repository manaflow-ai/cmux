import { describe, expect, test } from "bun:test";
import { FIXTURE_SELF, fixtureBoard, fixtureUpdates } from "./fixtures";
import { MockBoardProvider } from "./mockProvider";
import { addToTotals, compareRows, emptyTotals, joinRows, ownerOf, saneUsd, type BoardTotals } from "./model";
import { BoardStore } from "./store";
import type { BoardSnapshot, TeamMachine } from "./types";
import { OVERSCAN, ROW_HEIGHT, windowOf } from "./BoardPage";

const machine = (id: string, extra: Partial<TeamMachine> = {}): TeamMachine => ({
  id,
  state: "running",
  creator: "user_a",
  createdAt: 1,
  cost: { totalUsd: 1, hourlyUsd: 0.5 },
  ...extra,
});

/** A store whose frames run when the test says. */
function manualStore(provider: MockBoardProvider | null) {
  const frames: (() => void)[] = [];
  const store = new BoardStore(provider, (flush) => frames.push(flush));
  const frame = () => frames.splice(0).forEach((flush) => flush());
  return { store, frame, frames };
}

const sumTotals = (snapshot: BoardSnapshot): BoardTotals => {
  const totals = emptyTotals();
  for (const row of joinRows(snapshot)) addToTotals(totals, row, 1);
  return totals;
};

describe("model", () => {
  test("a cost that is negative, missing, NaN, infinite or a string is unknown", () => {
    for (const bad of [-1, undefined, null, Number.NaN, Number.POSITIVE_INFINITY, "NaN", "3"])
      expect(saneUsd(bad)).toBeNull();
    expect(saneUsd(0)).toBe(0);
    expect(saneUsd(2.5)).toBe(2.5);
  });

  test("owners: self, member, departed, none", () => {
    const members = new Map([["user_a", { user: "user_a", name: "Ada" }]]);
    expect(ownerOf("user_a", members, "user_me")).toEqual({ kind: "member", user: "user_a", name: "Ada" });
    expect(ownerOf("user_me", members, "user_me")).toEqual({ kind: "self", user: "user_me" });
    expect(ownerOf("user_gone", members, null)).toEqual({ kind: "unknown", user: "user_gone" });
    expect(ownerOf(undefined, members, null)).toEqual({ kind: "none" });
    expect(ownerOf("  ", members, null)).toEqual({ kind: "none" });
  });

  test("the join: usage fills a missing cost, the newest audit row wins, a duplicate shows once", () => {
    const rows = joinRows({
      machines: [machine("a", { cost: {} }), machine("b"), machine("b", { state: "paused" })],
      usage: {
        since: 0,
        until: 1,
        knownCostUsd: 4,
        totalCostUsd: 4,
        byCreator: [],
        byStartedBy: [],
        byMachine: [{ machineId: "a", hours: 1, costUsd: 4 }],
      },
      audit: [
        {
          at: 5,
          target: "machine",
          targetId: "b",
          creator: "",
          actor: "codex",
          actorKind: "agent",
          action: "resume",
          result: "ok",
        },
        {
          at: 9,
          target: "machine",
          targetId: "b",
          creator: "",
          actor: "ada",
          actorKind: "person",
          action: "open",
          result: "ok",
        },
      ],
    });
    expect(rows.map((row) => row.id)).toEqual(["a", "b"]);
    expect(rows[0]!.costUsd).toBe(4);
    expect(rows[1]!.last).toMatchObject({ action: "open", actor: "ada" });
  });

  test("order: waiting first, then failed, running, paused, newest first", () => {
    const rows = joinRows({
      machines: [
        machine("paused", { state: "paused", createdAt: 9 }),
        machine("old", { createdAt: 1 }),
        machine("new", { createdAt: 5 }),
        machine("failed", { state: "failed" }),
        machine("waiting", { createdAt: 0 }),
      ],
      sessions: { waiting: [{ id: "s", agent: "claude", state: "waiting" }] },
    });
    expect(rows.sort(compareRows).map((row) => row.id)).toEqual(["waiting", "failed", "new", "old", "paused"]);
  });

  test("a non-finite createdAt or an unknown state sorts consistently", () => {
    const rows = joinRows({
      machines: [
        machine("x", { createdAt: Number.NaN }),
        machine("y", { createdAt: Number.POSITIVE_INFINITY }),
        machine("z", { state: "hibernating" as never, createdAt: 3 }),
        machine("w", { createdAt: 2 }),
      ],
    });
    const once = [...rows].sort(compareRows).map((row) => row.id);
    const again = [...rows]
      .reverse()
      .sort(compareRows)
      .map((row) => row.id);
    expect(once).toEqual(again);
    expect(once).toEqual(["w", "x", "y", "z"]);
  });

  test("totals over the degenerate fixture count unknown costs instead of adding them", () => {
    const snapshot = fixtureBoard({ machines: 500, degenerate: true });
    const totals = sumTotals(snapshot);
    expect(totals.machines).toBe(500); // the machine listed twice counts once
    expect(totals.unknownCost).toBeGreaterThanOrEqual(40); // 4 bad costs every 50 machines
    expect(Number.isFinite(totals.costUsd) && totals.costUsd >= 0).toBe(true);
    expect(totals.unowned).toBeGreaterThanOrEqual(30); // 3 unowned every 50 machines
  });

  test("the window is the same size at 3 and at 5,000 machines", () => {
    const viewport = 800;
    const span = ([first, end]: [number, number]) => end - first;
    const limit = Math.ceil(viewport / ROW_HEIGHT) + 2 * OVERSCAN + 1;
    expect(span(windowOf(0, viewport, 3))).toBe(3);
    for (const top of [0, 1234, 100_000, 5000 * ROW_HEIGHT - viewport])
      expect(span(windowOf(top, viewport, 5000))).toBeLessThanOrEqual(limit);
    expect(windowOf(10 ** 9, viewport, 5000)[1]).toBe(5000);
  });
});

describe("store", () => {
  test("loads the snapshot: rows, totals and order", async () => {
    const provider = new MockBoardProvider({ machines: 100 });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    const state = store.getSnapshot();
    expect(state.loading).toBe(false);
    expect(state.visible.length).toBe(100);
    expect(state.totals).toEqual(sumTotals(fixtureBoard({ machines: 100 })));
  });

  test("100 changes in one frame publish once, and only the changed rows hear about it", async () => {
    const provider = new MockBoardProvider({ machines: 5000 });
    const { store, frame, frames } = manualStore(provider);
    await store.start();
    frame();
    let pageNotes = 0;
    store.subscribe(() => (pageNotes += 1));
    const heard = new Map<string, number>();
    for (const id of store.getSnapshot().visible.slice(0, 40))
      store.subscribeRow(id, () => heard.set(id, (heard.get(id) ?? 0) + 1));
    const updates = fixtureUpdates(fixtureBoard({ machines: 5000 }), 100);
    for (const event of updates) provider.push(event);
    expect(frames.length).toBe(1);
    frame();
    expect(pageNotes).toBe(1);
    const touched = new Set(
      updates.map((event) =>
        event.kind === "machine"
          ? event.machine.id
          : event.kind === "sessions"
            ? event.machine
            : event.kind === "audit"
              ? event.row.targetId
              : "",
      ),
    );
    for (const [id, count] of heard) {
      expect(touched.has(id)).toBe(true);
      expect(count).toBe(1);
    }
  });

  test("incremental totals equal a full recount after 2,000 random changes", async () => {
    const provider = new MockBoardProvider({ machines: 1000, seed: 7 });
    const { store, frame } = manualStore(provider);
    await store.start();
    const base = fixtureBoard({ machines: 1000, seed: 7 });
    const latest = new Map(base.machines.map((one) => [one.id, one]));
    const sessions = { ...base.sessions };
    for (const event of fixtureUpdates(base, 2000, 11)) {
      provider.push(event);
      if (event.kind === "machine") latest.set(event.machine.id, event.machine);
      if (event.kind === "sessions") sessions[event.machine] = event.sessions;
    }
    frame();
    const expected = sumTotals({ ...base, machines: [...latest.values()], sessions });
    const got = store.getSnapshot().totals;
    expect(got.machines).toBe(expected.machines);
    expect(got.running).toBe(expected.running);
    expect(got.waiting).toBe(expected.waiting);
    expect(got.unknownCost).toBe(expected.unknownCost);
    expect(got.costUsd).toBeCloseTo(expected.costUsd, 6);
    expect(got.hourlyUsd).toBeCloseTo(expected.hourlyUsd, 6);
  });

  test("a cost tick does not re-sort; a state change does", async () => {
    const provider = new MockBoardProvider({
      snapshot: { machines: [machine("a", { createdAt: 2 }), machine("b", { createdAt: 1 })] },
    });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    const before = store.getSnapshot().visible;
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2, cost: { totalUsd: 9 } }) });
    frame();
    expect(store.getSnapshot().visible).toBe(before);
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2, state: "paused" }) });
    frame();
    expect(store.getSnapshot().visible).toEqual(["b", "a"]);
  });

  test("filter and search answer in the same frame", async () => {
    const { store, frame } = manualStore(new MockBoardProvider({ machines: 500 }));
    await store.start();
    frame();
    store.setFilter("unowned");
    const unowned = store.getSnapshot().visible;
    expect(unowned.length).toBeGreaterThan(0);
    for (const id of unowned) expect(["none", "unknown"]).toContain(store.getRow(id)!.row.owner.kind);
    store.setFilter("all");
    store.setQuery(FIXTURE_SELF);
    expect(store.getSnapshot().visible.length).toBeGreaterThan(0);
  });

  test("Stop: the row says Stopping until the host answers, then shows the paused machine", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    provider.holdStop();
    const done = store.stopMachine("a");
    expect(store.getRow("a")!.stopping).toBe(true);
    void store.stopMachine("a"); // a second click while waiting sends nothing
    provider.finishStop();
    await done;
    expect(store.getRow("a")).toMatchObject({ stopping: false, row: { state: "paused" } });
    expect(provider.calls.filter((call) => call.op === "cmux.board.stop").length).toBe(1);
  });

  test("a refused Stop says why on the row", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a")] } });
    provider.stopRefusal = "busy";
    const { store } = manualStore(provider);
    await store.start();
    await store.stopMachine("a");
    expect(store.getRow("a")).toMatchObject({ stopping: false, refused: "busy", row: { state: "running" } });
  });

  test("a machine that goes away leaves the list and the totals", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a"), machine("b")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    provider.push({ kind: "gone", id: "a" });
    frame();
    expect(store.getSnapshot().visible).toEqual(["b"]);
    expect(store.getSnapshot().totals.machines).toBe(1);
    expect(store.getRow("a")).toBeUndefined();
  });

  test("no host: unavailable; a host without the board: unavailable; a failed read: says why", async () => {
    const none = manualStore(null);
    await none.store.start();
    expect(none.store.getSnapshot().unavailable).toBe(true);

    const provider = new MockBoardProvider({ machines: 3 });
    provider.call = async () => {
      throw Object.assign(new Error("cmux.board.snapshot"), { code: "cmux.protocol.unknown_op" });
    };
    const old = manualStore(provider);
    await old.store.start();
    expect(old.store.getSnapshot().unavailable).toBe(true);

    const failing = new MockBoardProvider({ machines: 3 });
    failing.call = async () => {
      throw Object.assign(new Error("platform answered 503"), { code: "cloud.unavailable" });
    };
    const failed = manualStore(failing);
    await failed.store.start();
    expect(failed.store.getSnapshot()).toMatchObject({ unavailable: false, failure: "platform answered 503" });
  });

  test("events that arrive while the snapshot is read are applied over it, not lost with it", async () => {
    const provider = new MockBoardProvider({ machines: 50 });
    const { store, frame } = manualStore(provider);
    const read = provider.call.bind(provider);
    const first = fixtureBoard({ machines: 50 }).machines[0]!;
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === "cmux.board.snapshot") provider.push({ kind: "machine", machine: { ...first, state: "failed" } });
      return read<R>(op, params);
    };
    await store.start();
    frame();
    const state = store.getSnapshot();
    expect(state.loading).toBe(false);
    expect(state.visible.length).toBe(50);
    expect(store.getRow(first.id)!.row.state).toBe("failed");
  });

  test("a Stop answer that comes after the machine went away does not bring it back", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a"), machine("b")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    provider.holdStop();
    const done = store.stopMachine("a");
    provider.push({ kind: "gone", id: "a" });
    provider.finishStop();
    await done;
    frame();
    expect(store.getRow("a")).toBeUndefined();
    expect(store.getSnapshot().visible).toEqual(["b"]);
    expect(store.getSnapshot().totals.machines).toBe(1);
  });

  test("a Stop answer older than the stream's record is not shown", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a")] } });
    const { store } = manualStore(provider);
    await store.start();
    provider.holdStop();
    const done = store.stopMachine("a");
    provider.push({ kind: "machine", machine: machine("a", { state: "failed" }) });
    provider.finishStop();
    await done;
    expect(store.getRow("a")).toMatchObject({ stopping: false, row: { state: "failed" } });
  });

  test("Stopping ends when the host answers, even with the machine still running and no stream", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a")] } });
    provider.subscribe = async () => {
      throw new Error("no stream");
    };
    const read = provider.call.bind(provider);
    provider.call = async <R>(op: string, params: unknown): Promise<R> =>
      op === "cmux.board.stop" ? (machine("a") as R) : read<R>(op, params);
    const { store } = manualStore(provider);
    await store.start();
    await store.stopMachine("a");
    expect(store.getRow("a")).toMatchObject({ stopping: false, row: { state: "running" } });
  });

  test("the gallery's Stop flow: rows exist once the snapshot is flushed, and Stop reaches the host", async () => {
    const provider = new MockBoardProvider({ machines: 20 });
    const { store } = manualStore(provider);
    await store.start();
    expect(store.getSnapshot().visible).toEqual([]);
    store.flush();
    const first = store.getSnapshot().visible.find((id) => store.getRow(id)?.row.state === "running");
    expect(first).toBeDefined();
    provider.holdStop();
    void store.stopMachine(first!);
    expect(provider.calls.filter((call) => call.op === "cmux.board.stop")).toHaveLength(1);
    expect(store.getRow(first!)?.stopping).toBe(true);
  });

  test("a machine removed and added back within one frame shows once", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a", { createdAt: 2 }), machine("b")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    provider.push({ kind: "gone", id: "a" });
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2 }) });
    frame();
    expect(store.getSnapshot().visible).toEqual(["a", "b"]);
    expect(store.getSnapshot().totals.machines).toBe(2);
    provider.push({ kind: "gone", id: "a" });
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2 }) });
    provider.push({ kind: "gone", id: "a" });
    frame();
    expect(store.getSnapshot().visible).toEqual(["b"]);
  });

  test("a Stop answer that lands during a snapshot read is applied over the snapshot", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    // The next read is taken while "a" still runs, and answers only after Stop did.
    const read = provider.call.bind(provider);
    let release = () => {};
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op !== "cmux.board.snapshot") return read<R>(op, params);
      const stale = { machines: [machine("a")] } as R;
      await new Promise<void>((resolve) => (release = resolve));
      return stale;
    };
    const refreshing = store.refresh();
    await store.stopMachine("a");
    release();
    await refreshing;
    frame();
    expect(store.getRow("a")).toMatchObject({ stopping: false, row: { state: "paused" } });
    expect(store.getSnapshot().totals.running).toBe(0);
  });

  test("a Stop or Open refusal that lands during a snapshot read still shows once the snapshot is in", async () => {
    const provider = new MockBoardProvider({ snapshot: { machines: [machine("a"), machine("b")] } });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    const read = provider.call.bind(provider);
    let release = () => {};
    provider.call = async <R>(op: string, params: unknown): Promise<R> => {
      if (op === "cmux.board.stop" || op === "cmux.board.open") throw new Error(`refused ${op}`);
      if (op !== "cmux.board.snapshot") return read<R>(op, params);
      const stale = { machines: [machine("a"), machine("b")] } as R;
      await new Promise<void>((resolve) => (release = resolve));
      return stale;
    };
    const refreshing = store.refresh();
    await store.stopMachine("a");
    await store.openMachine("b");
    release();
    await refreshing;
    frame();
    expect(store.getRow("a")).toMatchObject({ stopping: false, refused: "refused cmux.board.stop" });
    expect(store.getRow("b")).toMatchObject({ refused: "refused cmux.board.open" });
  });

  test("with a filter on, a cost tick neither re-sorts nor refilters; a change of filter result does", async () => {
    const provider = new MockBoardProvider({
      snapshot: { machines: [machine("a", { createdAt: 2 }), machine("b", { createdAt: 1 })] },
    });
    const { store, frame } = manualStore(provider);
    await store.start();
    frame();
    store.setFilter("running");
    const before = store.getSnapshot().visible;
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2, cost: { totalUsd: 9 } }) });
    frame();
    expect(store.getSnapshot().visible).toBe(before);
    provider.push({ kind: "machine", machine: machine("a", { createdAt: 2, state: "paused" }) });
    frame();
    expect(store.getSnapshot().visible).toEqual(["b"]);
  });
});
