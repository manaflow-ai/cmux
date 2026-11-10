// The board over the Cloud page's bridge (cloudClient.ts): each board op is the Cloud op the app
// already serves, and the change stream re-reads the board on machine changes, coalesced.
import { describe, expect, test } from "bun:test";
import type { PageClient } from "../shared/pageClient";
import { ACTION_RUN, CloudOps } from "../cloud/ops";
import { cloudBoardClient, isBoardRoute } from "./cloudClient";
import { BoardOps, type BoardEvent, type BoardSnapshot, type TeamMachine } from "./types";

const machine = (id: string, state: TeamMachine["state"] = "running"): TeamMachine => ({
  id,
  state,
  creator: "user_a",
});
const board = (...machines: TeamMachine[]): BoardSnapshot => ({
  machines,
  usage: null,
  audit: [],
  members: null,
  self: "user_a",
});

/** A Cloud page bridge that records calls, answers from `answers`, and lets the test fire watch events. */
function fakeCloud(answers: Record<string, (params: unknown) => unknown>) {
  const calls: { op: string; params: unknown }[] = [];
  const watchers = new Set<(data: unknown, seq: number) => void>();
  const client: PageClient = {
    async call<R>(op: string, params: unknown): Promise<R> {
      calls.push({ op, params });
      const answer = answers[op];
      if (!answer) throw Object.assign(new Error(op), { code: "cmux.protocol.unknown_op" });
      return (await answer(params)) as R;
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      if (stream !== CloudOps.machineWatch) throw new Error(stream);
      const watcher = onEvent as (data: unknown, seq: number) => void;
      watchers.add(watcher);
      return () => watchers.delete(watcher);
    },
    handle: () => () => {},
  };
  const fire = () => watchers.forEach((watcher) => watcher({ type: "upsert" }, 1));
  return { client, calls, fire, watchers };
}

/** Lets the awaited reads and their follow-ups run. */
const settle = async () => {
  for (let turn = 0; turn < 10; turn += 1) await Promise.resolve();
};

const keys = () => {
  let n = 0;
  return () => `key-${++n}`;
};

describe("the board over the Cloud bridge", () => {
  test("the snapshot is the Cloud board read, as it came", async () => {
    const cloud = fakeCloud({ [CloudOps.machineBoard]: () => board(machine("a")) });
    const snapshot = await cloudBoardClient(cloud.client).call<BoardSnapshot>(BoardOps.snapshot, {});
    expect(snapshot).toEqual(board(machine("a")));
    expect(cloud.calls).toEqual([{ op: CloudOps.machineBoard, params: {} }]);
  });

  test("Stop pauses with a key and answers the machine's board record read after it", async () => {
    let paused = false;
    const cloud = fakeCloud({
      [CloudOps.machinePause]: () => ((paused = true), { machine: { id: "a", status: "paused" }, revision: "2" }),
      [CloudOps.machineBoard]: () => board(machine("a", paused ? "paused" : "running"), machine("b")),
    });
    const answer = await cloudBoardClient(cloud.client, keys()).call<TeamMachine>(BoardOps.stop, { machine: "a" });
    expect(answer).toEqual(machine("a", "paused"));
    expect(cloud.calls[0]).toEqual({ op: CloudOps.machinePause, params: { machine: "a", idempotency_key: "key-1" } });
  });

  test("Stop still answers the pause's record when the read after it fails", async () => {
    const cloud = fakeCloud({ [CloudOps.machinePause]: () => ({ machine: machine("a", "paused") }) });
    const answer = await cloudBoardClient(cloud.client).call<TeamMachine>(BoardOps.stop, { machine: "a" });
    expect(answer).toEqual(machine("a", "paused"));
  });

  test("a refused Stop rejects with the server's error", async () => {
    const cloud = fakeCloud({
      [CloudOps.machinePause]: () => {
        throw Object.assign(new Error("not running"), { code: "cmux.cloud.not_running" });
      },
    });
    const stop = cloudBoardClient(cloud.client).call(BoardOps.stop, { machine: "a" });
    await expect(stop).rejects.toMatchObject({ code: "cmux.cloud.not_running" });
  });

  test("Open is the Cloud page's confirmed connect; a declined sheet opens nothing", async () => {
    let confirm = true;
    const cloud = fakeCloud({ [ACTION_RUN]: () => (confirm ? { confirmed: true, value: {} } : { confirmed: false }) });
    const client = cloudBoardClient(cloud.client, keys());
    expect(await client.call<{ opened: boolean }>(BoardOps.open, { machine: "a" })).toEqual({ opened: true });
    expect(cloud.calls[0]).toEqual({
      op: ACTION_RUN,
      params: { action: CloudOps.machineConnect, args: { machine: "a", idempotency_key: "key-1" } },
    });
    confirm = false;
    expect(await client.call<{ opened: boolean }>(BoardOps.open, { machine: "a" })).toEqual({ opened: false });
  });

  test("machine changes re-read the board: one read at a time, at most one queued", async () => {
    let release: (() => void) | undefined;
    let reads = 0;
    const cloud = fakeCloud({
      [CloudOps.machineBoard]: () =>
        new Promise<BoardSnapshot>((resolve) => {
          reads += 1;
          const n = reads;
          release = () => resolve(board(machine(`m${n}`)));
        }),
    });
    const events: BoardEvent[] = [];
    const stop = await cloudBoardClient(cloud.client).subscribe<BoardEvent>(BoardOps.changes, (event) =>
      events.push(event),
    );
    cloud.fire();
    cloud.fire();
    cloud.fire();
    expect(reads).toBe(1);
    release!();
    await settle();
    expect(reads).toBe(2);
    release!();
    await settle();
    expect(reads).toBe(2);
    expect(events).toEqual([
      { kind: "snapshot", snapshot: board(machine("m1")) },
      { kind: "snapshot", snapshot: board(machine("m2")) },
    ]);
    stop();
    expect(cloud.watchers.size).toBe(0);
  });

  test("the Cloud page's #/board fragment shows the board", () => {
    expect(isBoardRoute("#/board")).toBe(true);
    expect(isBoardRoute("#/board/")).toBe(true);
    expect(isBoardRoute("#/get")).toBe(false);
    expect(isBoardRoute("")).toBe(false);
  });
});
