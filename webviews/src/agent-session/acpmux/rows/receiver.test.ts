// The document's receiver paced by the frame lane (receiver.ts): a batch is applied in the frame
// lane, in slices that break only between changes, and taken at that frame's commit; a hidden page
// takes nothing until it is shown. Run on a fake engine (manual clock, rAF and task queues), with
// the v2 row host's pacing: it sends the next batch only after `taken`, in a later task.
import { afterEach, expect, test } from "bun:test";
import { createLanes, type Lanes, type LanesEnv } from "../schedule";
import { ChatRowsHost } from "./host";
import { addChatRowsHost, receiveChatRows, resetChatRowsReceiver } from "./receiver";
import type { ChatChange, ChatRow } from "./wire";

function fakeEngine() {
  let time = 0;
  let hidden = false;
  let frames: (() => void)[] = [];
  const tasks: (() => void)[] = [];
  const listeners = new Map<string, Set<() => void>>();
  const errors: unknown[] = [];
  const env: LanesEnv = {
    now: () => time,
    requestFrame: (cb) => frames.push(cb),
    postTask: (cb) => tasks.push(cb),
    // The occluded-window fallback timer never fires here: every frame is run by the test.
    setTimer: () => () => {},
    hidden: () => hidden,
    listen: (type, cb) => {
      const set = listeners.get(type) ?? new Set();
      set.add(cb);
      listeners.set(type, set);
      return () => set.delete(cb);
    },
    reportError: (error) => errors.push(error),
  };
  const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  const fire = (type: string) => {
    for (const cb of listeners.get(type) ?? []) cb();
  };
  return {
    env,
    errors,
    advance(ms: number) {
      time += ms;
    },
    pendingFrames: () => frames.length,
    /** One display frame: its rAF callbacks, then every task posted meanwhile (the host's too). */
    async frame() {
      const run = frames;
      frames = [];
      for (const cb of run) cb();
      await settle();
      for (let i = 0; i < 100 && tasks.length; i++) {
        tasks.shift()!();
        await settle();
      }
    },
    /** Tasks only, no frame: what runs between frames, or on a hidden page. */
    async tasks() {
      await settle();
      for (let i = 0; i < 100 && tasks.length; i++) {
        tasks.shift()!();
        await settle();
      }
    },
    /** A task from outside the page (the host's reply), run with the others after a frame. */
    hostTask(cb: () => void) {
      tasks.push(cb);
    },
    key() {
      fire("keydown");
    },
    setHidden(value: boolean) {
      hidden = value;
      fire("visibilitychange");
    },
  };
}

const SID = "s.1";
function row(id: number, text = `row ${id}`): ChatRow {
  return { id, rev: 1, kind: "text", turn: id, at: 1794480726 + id, open: false, body: { text }, est: 1 };
}
const rowChange = (id: number, text?: string) =>
  JSON.stringify({ kind: "chatOp", sid: SID, replay: false, op: { op: "row", seq: id, row: row(id, text) } });

type Post = { method: string; params: Record<string, unknown> };

function setup() {
  const engine = fakeEngine();
  const lanes: Lanes = createLanes(engine.env);
  const posts: Post[] = [];
  /** Called with each `taken` the page posts. */
  let onTaken: (batch: number) => void = () => {};
  const post = async (method: string, params: Record<string, unknown>) => {
    posts.push({ method, params });
    if (method === "chat.rows.taken") onTaken(params.batch as number);
    return {};
  };
  const host = new ChatRowsHost(post, undefined, () => SID);
  addChatRowsHost(host, post);
  host.store.open(SID);
  const window = { sid: SID, cursor: 0, edition: 1, rows: [row(0)], hasBefore: false, hasAfter: false };
  host.store.applyBatch([{ kind: "chatWindow", replaces: true, window } as unknown as ChatChange]);
  const told: number[] = [];
  host.store.subscribe(SID, (snapshot) => told.push(snapshot.rows.length));
  const taken = () => posts.filter((p) => p.method === "chat.rows.taken").map((p) => p.params.batch as number);
  return {
    engine,
    lanes,
    host,
    told,
    taken,
    onTaken: (fn: (batch: number) => void) => {
      onTaken = fn;
    },
  };
}

let made: Lanes[] = [];
afterEach(() => {
  for (const lanes of made) lanes.dispose();
  made = [];
  resetChatRowsReceiver();
});

test("taken is not answered in the receiving task, but at the frame's commit, after the subscribers were told", async () => {
  const { engine, lanes, told, taken, onTaken } = setup();
  made.push(lanes);
  let toldWhenTaken = -1;
  onTaken(() => (toldWhenTaken = told.length));
  receiveChatRows({ batch: 1, changes: [rowChange(1), rowChange(2)] }, lanes);
  expect(taken()).toEqual([]);
  expect(told).toEqual([]);
  await engine.tasks();
  expect(taken()).toEqual([]);
  await engine.frame();
  expect(taken()).toEqual([1]);
  // One snapshot for the batch, with both rows, told before `taken`.
  expect(told).toEqual([3]);
  expect(toldWhenTaken).toBe(1);
});

test("one taken per frame against a host that sends the next batch after taken", async () => {
  const { engine, lanes, taken, onTaken } = setup();
  made.push(lanes);
  let sent = 0;
  const send = () => {
    sent += 1;
    receiveChatRows({ batch: sent, changes: [rowChange(sent * 2 - 1), rowChange(sent * 2)] }, lanes);
  };
  // The host reads `taken` in a later task, then sends.
  onTaken(() => engine.hostTask(send));
  send();
  const perFrame: number[] = [];
  for (let frame = 0; frame < 6; frame += 1) {
    const before = taken().length;
    await engine.frame();
    perFrame.push(taken().length - before);
  }
  expect(perFrame).toEqual([1, 1, 1, 1, 1, 1]);
  expect(taken()).toEqual([1, 2, 3, 4, 5, 6]);
});

test("a hidden page takes nothing; on show it applies and takes in one frame", async () => {
  const { engine, lanes, told, taken } = setup();
  made.push(lanes);
  engine.setHidden(true);
  receiveChatRows({ batch: 4, changes: [rowChange(1)] }, lanes);
  await engine.tasks();
  expect(engine.pendingFrames()).toBe(0);
  await engine.frame();
  expect(taken()).toEqual([]);
  expect(told).toEqual([]);
  engine.setHidden(false);
  await engine.frame();
  expect(taken()).toEqual([4]);
  expect(told).toEqual([2]);
});

test("a 256 KiB change gives way to a pending key before and after it, and is applied whole", async () => {
  const { engine, lanes, host, taken } = setup();
  made.push(lanes);
  const big = "x".repeat(256 * 1024);
  const applied: { id: number; bytes: number }[] = [];
  const applyPart = host.store.applyPart.bind(host.store);
  host.store.applyPart = (part, changes) => {
    for (const change of changes)
      if (change.kind === "chatOp" && change.op.op === "row") {
        const text = (change.op.row.body as { text: string }).text;
        applied.push({ id: change.op.row.id, bytes: text.length });
      }
    applyPart(part, changes);
    // A key comes in while each change is applied.
    engine.key();
  };
  receiveChatRows({ batch: 9, changes: [rowChange(1), rowChange(2, big), rowChange(3)] }, lanes);
  // Frame 1: the first change, then the key is pending: the big one waits.
  await engine.frame();
  expect(applied.map((a) => a.id)).toEqual([1]);
  expect(taken()).toEqual([]);
  // Frame 2: the big change alone, whole; the key that came during it holds the third.
  engine.advance(16);
  await engine.frame();
  expect(applied).toEqual([
    { id: 1, bytes: 5 },
    { id: 2, bytes: 256 * 1024 },
  ]);
  expect(taken()).toEqual([]);
  // Frame 3: the last change, and the batch is taken.
  engine.advance(16);
  await engine.frame();
  expect(applied.map((a) => a.id)).toEqual([1, 2, 3]);
  expect(taken()).toEqual([9]);
  expect(host.store.snapshot(SID)!.rows.length).toBe(4);
  expect(engine.errors).toEqual([]);
});

test("a line that is not a change and a store that throws: the batch is still taken, the next one too, the error reported", async () => {
  const { engine, lanes, host, taken } = setup();
  made.push(lanes);
  const applyPart = host.store.applyPart.bind(host.store);
  let throwOnce = true;
  host.store.applyPart = (part, changes) => {
    if (throwOnce) {
      throwOnce = false;
      throw new Error("broken store");
    }
    applyPart(part, changes);
  };
  const notChanges = [42, "{", JSON.stringify({ kind: "chatWindow" })] as unknown as string[];
  receiveChatRows({ batch: 1, changes: [rowChange(1), ...notChanges, rowChange(2)] }, lanes);
  await engine.frame();
  expect(taken()).toEqual([1]);
  expect(engine.errors.map((error) => (error as Error).message)).toEqual(["broken store"]);
  receiveChatRows({ batch: 2, changes: [rowChange(3)] }, lanes);
  await engine.frame();
  expect(taken()).toEqual([1, 2]);
});
