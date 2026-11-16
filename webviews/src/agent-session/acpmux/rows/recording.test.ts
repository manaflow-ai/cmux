// The page's row store fed the one recording of a daemon's chat stream (decision 242, row 6b):
// each step's change strings as the client core gave them, through the host client, with the
// page's calls in between as the recording made them. Nothing here is recorded again.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ChatRowsHost } from "./host";
import { type ChatFall, ChatRowStore, type ChatRowsSnapshot } from "./store";

const FIXTURES = `${import.meta.dir}/../../../../../Packages/macOS/CmuxNext/Tests/Fixtures/AgentChatStream`;

type Line =
  | { surfaces: string[] }
  | { step: string }
  | { call: string; request?: Record<string, unknown>; reply?: unknown }
  | { feed: [number, number] }
  | string;

/// The recording's steps: each one's calls, then its change strings, in order.
function steps(name: string): Map<string, { calls: Line[]; changes: string[] }> {
  const out = new Map<string, { calls: Line[]; changes: string[] }>();
  let step = { calls: [] as Line[], changes: [] as string[] };
  for (const text of readFileSync(`${FIXTURES}/${name}.jsonl`, "utf8").split("\n")) {
    if (!text.trim()) continue;
    const line = JSON.parse(text) as Line;
    if (typeof line === "string") step.changes.push(line);
    else if ("step" in line) out.set(line.step, (step = { calls: [], changes: [] }));
    else if ("call" in line) step.calls.push(line);
  }
  return out;
}

/// A host whose names are the recording's: the sids, then `blob.1`, `blob.2`, ...
function recorded(sids: string[]) {
  const posts: { method: string; params: Record<string, unknown> }[] = [];
  const falls: ChatFall[] = [];
  let blobs = 0;
  const names = [...sids];
  const store = new ChatRowStore({ onFall: (fall) => falls.push(fall) });
  const host = new ChatRowsHost(
    async (method, params) => {
      posts.push({ method, params });
      if (method === "chat.rows.open") return { sid: params.sid };
      if (method === "chat.rows.blob") return { id: params.id };
      return {};
    },
    store,
    () => names.shift() ?? `blob.${++blobs}`,
  );
  let batch = 0;
  const feed = (changes: string[]) => host.receive({ batch: ++batch, changes });
  return { host, store, posts, falls, feed };
}

const ids = (snapshot: ChatRowsSnapshot) => snapshot.rows.map((entry) => entry.id);
const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, index) => from + index);

test("the chat recording, step by step", async () => {
  const recording = steps("chat");
  // Steps recorded for a later piece: the page of turns' PR (6d) replays them and empties this.
  // Any other new step fails here.
  const NOT_YET = ["page-turns", "page-turns-unsupported"];
  expect([...recording.keys()].filter((name) => !NOT_YET.includes(name))).toEqual([
    "upgrade",
    "not-ready",
    "window",
    "ops",
    "resume",
    "window-same-edition",
    "window-new-edition",
    "page",
    "page-stale",
    "blob-settled",
    "blob-open-first",
    "blob-open-rest",
    "dropped",
    "sub-error",
    "after-end",
  ]);
  const { host, store, posts, falls, feed } = recorded(["rows.1"]);
  const step = (name: string) => feed(recording.get(name)!.changes);
  const snapshot = () => store.snapshot("rows.1")!;
  // The request the recording's call made, as the page's post made it.
  const asked = (name: string) => {
    const call = recording.get(name)!.calls[0] as { request: Record<string, unknown> };
    expect(posts.at(-1)!.params).toEqual(call.request);
  };

  expect(await host.open("chat-a")).toEqual({ sid: "rows.1" });
  step("upgrade");
  step("not-ready");
  expect(store.has("rows.1")).toBe(true);
  expect(snapshot().ready).toBe(false);

  step("window");
  expect(ids(snapshot())).toEqual(range(1, 11));
  expect(snapshot().rows.at(-1)!.row!.open).toBe(true);
  expect(snapshot().seen).toBe(10);

  step("ops");
  expect(ids(snapshot())).toEqual(range(1, 12));
  expect(snapshot().rows[10]!.row!.open).toBeFalsy();
  expect((snapshot().rows[11]!.row!.body as { text: string }).text).toBe("the next turn — on");
  expect(snapshot().rows[3]!.rev).toBe(2);
  expect(snapshot().queue.entries.map((entry) => entry.id)).toEqual(["p1", "p2"]);
  expect(snapshot().queue.count).toBe(2);

  // A resume's ops are drawn in one step at its end.
  const drawn: ChatRowsSnapshot[] = [];
  const stop = store.subscribe("rows.1", (next) => drawn.push(next));
  step("resume");
  stop();
  expect(drawn.length).toBe(1);
  expect(ids(snapshot())).toEqual(range(1, 14));
  expect(snapshot().rows[11]!.row!.open).toBeFalsy();

  // A window in place of a resume, same edition, that does not reach the rows held: a gap
  // before its first row, and the rows held stay unconfirmed.
  step("window-same-edition");
  expect(ids(snapshot())).toEqual([...range(1, 14), ...range(31, 40)]);
  expect(
    snapshot()
      .rows.filter((entry) => entry.gapBefore)
      .map((entry) => entry.id),
  ).toEqual([31]);
  expect(
    snapshot()
      .rows.filter((entry) => entry.unconfirmed)
      .map((entry) => entry.id),
  ).toEqual(range(1, 14));
  expect(store.edge("rows.1", "before")).toBe(31);

  // A new edition replaces everything; its open row's body is behind `blob`.
  step("window-new-edition");
  expect(ids(snapshot())).toEqual(range(21, 30));
  expect(snapshot().rows.at(-1)!.bodyLen).toBe(37);
  expect(snapshot().rows.some((entry) => entry.gapBefore || entry.unconfirmed)).toBe(false);

  expect(host.page("rows.1", "before")).toBe(true);
  asked("page");
  step("page");
  expect(ids(snapshot())).toEqual(range(18, 30));
  expect(snapshot().hasBefore).toBe(true);

  expect(host.page("rows.1", "before", { from: 18, maxBytes: 4096 })).toBe(true);
  asked("page-stale");
  const beforeStale = snapshot();
  step("page-stale");
  expect(snapshot()).toBe(beforeStale);
  expect(store.pageOut("rows.1")).toBe(false);

  expect(await host.blob("rows.1", { rowId: 25 }, 4096)).toBe("blob.1");
  asked("blob-settled");
  step("blob-settled");
  expect(snapshot().bodies.get("row:25")).toEqual(snapshot().rows.find((entry) => entry.id === 25)!.row!.body);

  // The first range ends inside an escape: the next starts at `nextStart`, not at start + len.
  expect(await host.blob("rows.1", { rowId: 30 }, 25)).toBe("blob.2");
  asked("blob-open-first");
  step("blob-open-first");
  expect(snapshot().bodies.has("row:30")).toBe(false);
  expect(await host.blob("rows.1", { rowId: 30 }, 15, { start: 22 })).toBe("blob.3");
  asked("blob-open-rest");
  step("blob-open-rest");
  const body = snapshot().bodies.get("row:30") as { text: string };
  expect(typeof body.text).toBe("string");

  // Dropped and subscribed again: a window that reaches the rows held confirms them.
  step("dropped");
  expect(ids(snapshot())).toEqual(range(18, 30));
  expect(snapshot().rows.at(-1)!.row!.open).toBeFalsy();
  expect(snapshot().rows.some((entry) => entry.gapBefore)).toBe(false);

  expect(falls).toEqual([]);
  step("sub-error");
  expect(falls).toEqual([{ sid: "rows.1", code: "source_failed" }]);
  expect(store.has("rows.1")).toBe(false);
  step("after-end");
  expect(store.has("rows.1")).toBe(false);
});

test("the fallback recording: each sub falls to v1, then the connection's fallback changes nothing", async () => {
  const recording = steps("fallback");
  const { host, store, falls, feed } = recorded(["rows.1", "rows.2"]);
  expect(await host.open("chat-a")).toEqual({ sid: "rows.1" });
  expect(await host.open("chat-b")).toEqual({ sid: "rows.2" });
  for (const { changes } of recording.values()) feed(changes);
  expect(falls).toEqual([
    { sid: "rows.1", code: "surface_off" },
    { sid: "rows.2", code: "surface_off" },
  ]);
  expect(store.has("rows.1") || store.has("rows.2")).toBe(false);
});
