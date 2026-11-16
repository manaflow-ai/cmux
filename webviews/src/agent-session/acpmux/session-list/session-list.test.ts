import { afterEach, expect, test } from "bun:test";
import { createLanes, type Lanes, type LanesEnv } from "../schedule";
import { SessionListHost } from "./host";
import { listenForSessionList, receiveSessionList, resetSessionListReceiver } from "./receiver";
import { LIST_MAX_QUESTIONS, SessionListStore, type SessionListBatch } from "./store";

type Call = { method: string; params: Record<string, unknown> };

function engine() {
  let now = 0;
  let hidden = false;
  let frames: (() => void)[] = [];
  const tasks: (() => void)[] = [];
  const listeners = new Map<string, Set<() => void>>();
  const errors: unknown[] = [];
  const env: LanesEnv = {
    now: () => now,
    requestFrame: (callback) => frames.push(callback),
    postTask: (callback) => tasks.push(callback),
    setTimer: () => () => {},
    hidden: () => hidden,
    listen: (type, callback) => {
      const set = listeners.get(type) ?? new Set<() => void>();
      set.add(callback);
      listeners.set(type, set);
      return () => set.delete(callback);
    },
    reportError: (error) => errors.push(error),
  };
  const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
  return {
    env,
    errors,
    async frame() {
      const callbacks = frames;
      frames = [];
      for (const callback of callbacks) callback();
      await settle();
      for (let count = 0; count < 100 && tasks.length; count += 1) {
        tasks.shift()!();
        await settle();
      }
    },
    setHidden(value: boolean) {
      hidden = value;
      for (const callback of listeners.get("visibilitychange") ?? []) callback();
    },
    lanes(): Lanes {
      return createLanes(env);
    },
  };
}

const row = (id: string) => ({ sessionId: id, chatId: id, title: id });
const rowsChange = (sid: string, ids: string[]) => ({
  kind: "rows",
  sid,
  slot: "all",
  upserts: ids.map(row),
  remove: [],
  complete: true,
});

const pageChange = (sid: string, id: string, complete = true) => ({
  kind: "page" as const,
  sid,
  id,
  rows: [row("page-row")],
  hasBefore: false,
  hasAfter: false,
  complete,
  coldUnread: false,
  deeper: [],
  missing: [],
  unknown: [],
});

const lanesMade: Lanes[] = [];
afterEach(() => {
  for (const lanes of lanesMade) lanes.dispose();
  lanesMade.length = 0;
  resetSessionListReceiver();
});

test("registers before open, applies a batch once, and takes after subscribers", async () => {
  const clock = engine();
  const lanes = clock.lanes();
  lanesMade.push(lanes);
  const calls: Call[] = [];
  const host = new SessionListHost(
    async (method, params) => {
      calls.push({ method, params });
      if (method === "list.open") {
        receiveSessionList({ batch: 1, changes: [rowsChange(params.sid as string, ["a", "b"])] }, lanes);
        return { sid: params.sid };
      }
      return {};
    },
    new SessionListStore(),
    () => "s.1",
  );
  const opened = await host.open();
  expect(opened).toEqual({ sid: "s.1" });
  const snapshots: string[][] = [];
  host.store.subscribe("s.1", (snapshot) => snapshots.push(snapshot.slots.get("all")!.map((item) => item.sessionId)));
  await clock.frame();
  expect(snapshots).toEqual([["a", "b"]]);
  expect(calls.filter((call) => call.method === "list.taken").map((call) => call.params.batch)).toEqual([1]);
});

test("malformed and unknown changes never prevent one taken", async () => {
  const clock = engine();
  const lanes = clock.lanes();
  lanesMade.push(lanes);
  const calls: Call[] = [];
  const host = new SessionListHost(
    async (method, params) => {
      calls.push({ method, params });
      return method === "list.open" ? { sid: params.sid } : {};
    },
    new SessionListStore(),
    () => "s.1",
  );
  await host.open();
  listenForSessionList(lanes);
  receiveSessionList(
    {
      batch: 2,
      changes: [
        42,
        { kind: "rows", sid: "unknown", slot: "all", upserts: [], remove: [], complete: true },
        rowsChange("s.1", ["ok"]),
      ],
    },
    lanes,
  );
  await clock.frame();
  expect(
    host.store
      .snapshot("s.1")!
      .slots.get("all")!
      .map((item) => item.sessionId),
  ).toEqual(["ok"]);
  expect(calls.filter((call) => call.method === "list.taken").map((call) => call.params.batch)).toEqual([2]);
});

test("the checked-in ListBatch bytes are applied once by the document store", async () => {
  const clock = engine();
  const lanes = clock.lanes();
  lanesMade.push(lanes);
  const calls: Call[] = [];
  const host = new SessionListHost(
    async (method, params) => {
      calls.push({ method, params });
      return method === "list.open" ? { sid: params.sid } : {};
    },
    new SessionListStore(),
    () => "fixture-sid",
  );
  await host.open();
  host.store.questionAsked("fixture-sid", "q-older", "older");
  host.store.questionAsked("fixture-sid", "q-family", "family");
  const fixture = JSON.parse(
    await Bun.file(new URL("./fixtures/v2-session-list-batch.bin", import.meta.url)).text(),
  ) as SessionListBatch;
  receiveSessionList(fixture, lanes);
  await clock.frame();
  const snapshot = host.store.snapshot("fixture-sid")!;
  expect(snapshot.slots.get("all")?.map((item) => item.chatId)).toEqual(["chat-b", "chat-old"]);
  expect(snapshot.slots.get("live")?.map((item) => item.chatId)).toEqual(["chat-live"]);
  expect(snapshot.questions.get("q-older")?.rows).toEqual([]);
  expect(snapshot.questions.get("q-family")?.deeper).toEqual([{ origin: "local", chatId: "chat-child" }]);
  expect(snapshot.off).toBe("lost");
  expect(snapshot.error).toBe("list.protocol");
  expect(calls.filter((call) => call.method === "list.taken")).toHaveLength(1);
});

test("question ids are opaque and a page event may beat its operation reply", async () => {
  const clock = engine();
  const lanes = clock.lanes();
  lanesMade.push(lanes);
  let answer: ((value: unknown) => void) | undefined;
  const host = new SessionListHost(
    async (method, params) => {
      if (method === "list.open") return { sid: params.sid };
      if (method === "list.page") {
        receiveSessionList({ batch: 3, changes: [pageChange(params.sid as string, "q1")] }, lanes);
        return new Promise((resolve) => (answer = resolve));
      }
      return {};
    },
    new SessionListStore(),
    () => "local.1",
  );
  await host.open();
  const seen: string[] = [];
  host.store.subscribe("local.1", (snapshot) => seen.push([...snapshot.questions.keys()][0] ?? ""));
  const page = host.page("local.1", { kind: "family", key: { origin: "local", chatId: "head" } });
  await clock.frame();
  expect(seen).toEqual([]);
  answer!({ id: "q1" });
  expect(await page).toBe("q1");
  expect(seen).toEqual(["q1"]);
  expect(host.store.snapshot("local.1")!.questions.get("q1")!.rows[0]!.sessionId).toBe("page-row");
});

test("question and wanted-key bounds are enforced, and completed questions free a slot", () => {
  const store = new SessionListStore();
  store.open("s.1");
  for (let index = 0; index < LIST_MAX_QUESTIONS; index += 1) store.questionAsked("s.1", `q${index}`, "family");
  expect(() => store.questionAsked("s.1", "q16", "family")).toThrow("list.busy");
  store.apply(pageChange("s.1", "q0"));
  store.commit("s.1");
  expect(() => store.questionAsked("s.1", "q16", "family")).not.toThrow();
});

test("on clears a lost state and closes one question without closing its sid", async () => {
  const clock = engine();
  const lanes = clock.lanes();
  lanesMade.push(lanes);
  const calls: Call[] = [];
  const host = new SessionListHost(
    async (method, params) => {
      calls.push({ method, params });
      return method === "list.open" ? { sid: params.sid } : {};
    },
    new SessionListStore(),
    () => "s.on",
  );
  await host.open();
  const id = (await host.page("s.on", { kind: "family" })) as string;
  host.store.apply({ kind: "off", sid: "s.on", code: "lost" });
  host.store.commit("s.on");
  expect(host.store.snapshot("s.on")?.off).toBe("lost");
  receiveSessionList({ batch: 9, changes: [{ kind: "on", sid: "s.on" }] }, lanes);
  await clock.frame();
  expect(host.store.snapshot("s.on")?.off).toBeUndefined();
  expect(await host.closeQuestion("s.on", id)).toEqual({ ok: true });
  expect(calls.filter((call) => call.method === "list.close")).toEqual([
    { method: "list.close", params: { sid: "s.on", id } },
  ]);
  expect(host.store.has("s.on")).toBe(true);
});

test("page refuses unknown caller fields before posting wire-shaped data", async () => {
  const host = new SessionListHost(
    async (method, params) => (method === "list.open" ? { sid: params.sid } : {}),
    new SessionListStore(),
    () => "s.request",
  );
  await host.open();
  expect(await host.page("s.request", { kind: "family", cursor: "wire" })).toEqual({ ok: false, code: "list.request" });
});
