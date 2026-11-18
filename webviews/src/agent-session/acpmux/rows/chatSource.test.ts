// Where a chat's rows come from (chatSource.ts), played against the recordings of a daemon's chat
// stream (Packages/macOS/CmuxNext/Tests/Fixtures/AgentChatStream): the switch, the open's deadline,
// kept windows, one chat on the store a pane, and the falls to v1. The recording's rows are of kind
// `assistant`, which the adapter draws nothing of; here they are read as `text` rows, so each one
// draws one view row.
import { afterEach, expect, jest, test, beforeEach } from "bun:test";
import { readFileSync } from "node:fs";
import {
  ChatSource,
  HOLD_ATTACH_CAPABILITY,
  KEPT_WINDOWS,
  chatRowsOtherSids,
  chatRowsState,
  resetChatRowsState,
} from "./chatSource";
import { CHAT_ROWS_LATE, CHAT_ROWS_LOST, CHAT_ROWS_SLOW, OPEN_ANSWER_MS } from "./host";
import { receiveChatRows, resetChatRowsReceiver, listenForChatRows } from "./receiver";
import { syncLanes } from "../../../../test/support/chatRowsFeed";

const FIXTURES = `${import.meta.dir}/../../../../../Packages/macOS/CmuxNext/Tests/Fixtures/AgentChatStream`;
const HOLDS: ReadonlySet<string> = new Set([HOLD_ATTACH_CAPABILITY]);

/// A recording's change strings by step, its rows read as text rows.
function steps(name: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let changes: string[] = [];
  for (const text of readFileSync(`${FIXTURES}/${name}.jsonl`, "utf8").split("\n")) {
    if (!text.trim()) continue;
    const line = JSON.parse(text) as unknown;
    if (typeof line === "string") changes.push(line.replaceAll('"kind":"assistant"', '"kind":"text"'));
    else if (line && typeof line === "object" && "step" in line) out.set(String(line.step), (changes = []));
  }
  return out;
}
const chat = steps("chat");
const renamed = (changes: readonly string[], sid: string) =>
  changes.map((line) => line.replaceAll('"rows.1"', `"${sid}"`));

type Post = { method: string; params: Record<string, unknown> };

/// A source whose host answers each open with its sid unless `answer` says otherwise, and names
/// sids `rows.1`, `rows.2`, ... as the recording does.
/// Sources made by a test, dropped after it: each one adds its host to the document's receiver.
const made: ChatSource[] = [];

function source(answer?: (post: Post) => Promise<unknown> | undefined, prefix = "rows") {
  const posts: Post[] = [];
  const drawn: string[] = [];
  const fell: { chat: string; code: string }[] = [];
  let next = 0;
  const rows = new ChatSource(
    async (method, params) => {
      const post = { method, params };
      posts.push(post);
      const answered = answer?.(post);
      if (answered) return answered;
      return method === "chat.rows.open" ? { sid: params.sid } : {};
    },
    {
      context: (sessionId) => ({ sessionId }),
      rows: (sessionId) => drawn.push(sessionId),
      fell: (sessionId, code) => fell.push({ chat: sessionId, code }),
    },
    () => `${prefix}.${++next}`,
  );
  let batch = 0;
  const feed = (changes: readonly string[]) => rows.receive({ batch: ++batch, changes });
  const opens = () => posts.filter((post) => post.method === "chat.rows.open").length;
  made.push(rows);
  return { rows, posts, drawn, fell, feed, opens };
}

// These tests are about where changes go, not when (receiver.test.ts covers the frame pacing).
beforeEach(() => listenForChatRows(syncLanes()));

afterEach(() => {
  for (const rows of made.splice(0)) rows.dispose();
  resetChatRowsState();
  resetChatRowsReceiver();
  jest.useRealTimers();
});

test("no open is asked of a daemon without the hold, and a host's off is remembered", async () => {
  const { rows, opens } = source((post) =>
    post.method === "chat.rows.open"
      ? Promise.reject(
          Object.assign(new Error("unknown"), {
            code: "native.invalid_request",
            details: { protocol: "cmux.protocol.unknown_op" },
          }),
        )
      : undefined,
  );
  expect(rows.asks(undefined)).toBe(false);
  expect(rows.asks(new Set(["settled-attach-v1"]))).toBe(false);
  expect(await rows.choose("chat-a", undefined)).toBe(false);
  expect(opens()).toBe(0);
  expect(rows.asks(HOLDS)).toBe(true);
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(chatRowsState()).toBe("off");
  // Off: every chat after is v1 at once, with nothing posted.
  expect(rows.asks(HOLDS)).toBe(false);
  expect(await rows.choose("chat-b", HOLDS)).toBe(false);
  expect(opens()).toBe(1);
});

test("an open the host answers late falls with chat.rows.late, closes its sid and is not remembered", async () => {
  expect(OPEN_ANSWER_MS).toBe(250);
  const never = new Promise<unknown>(() => {});
  const { rows, posts, feed, opens } = source((post) => (post.method === "chat.rows.open" ? never : undefined));
  rows.host.answerMs = 5;
  const falls: string[] = [];
  const open = rows.host.open.bind(rows.host);
  rows.host.open = async (...args) => {
    const opened = await open(...args);
    if ("fallen" in opened) falls.push(opened.fallen);
    return opened;
  };
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(falls).toEqual([CHAT_ROWS_LATE]);
  expect(posts.at(-1)).toEqual({ method: "chat.rows.close", params: { sid: "rows.1" } });
  expect(rows.host.store.has("rows.1")).toBe(false);
  // What comes for the late sid is dropped.
  feed(chat.get("window")!);
  expect(rows.view("chat-a")).toBeUndefined();
  expect(chatRowsState()).toBe("unknown");
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(opens()).toBe(2);
});

test("the store's rows, one onRows a batch, and a text op adapts only its row", async () => {
  const { rows, drawn, feed } = source();
  expect(await rows.choose("chat-a", HOLDS)).toBe(true);
  expect(rows.holds("chat-a")).toBe(true);
  feed(chat.get("upgrade")!);
  feed(chat.get("not-ready")!);
  expect(drawn).toEqual([]);
  expect(rows.view("chat-a")).toBeUndefined();
  feed(chat.get("window")!);
  expect(drawn).toEqual(["chat-a"]);
  const window = rows.view("chat-a")!;
  expect(window.rows.map((row) => row.id)).toEqual(Array.from({ length: 11 }, (_, n) => `row-${n + 1}`));
  // A batch of N changes: one call.
  const ops = chat.get("ops")!;
  expect(ops.length).toBeGreaterThan(1);
  feed(ops.slice(0, 2));
  expect(drawn.length).toBe(2);
  const before = rows.view("chat-a")!;
  // One text op: one call, and every view row but its own is the same object.
  const text = ops.find((line) => line.includes('"op":"text"'))!;
  feed([text]);
  expect(drawn.length).toBe(3);
  const after = rows.view("chat-a")!;
  expect(after.rows.length).toBe(before.rows.length);
  const changed = after.rows.filter((row, at) => row !== before.rows[at]).map((row) => row.id);
  expect(changed).toEqual(["row-12"]);
  feed(ops.slice(3));
  expect(drawn.length).toBe(4);
  expect(rows.view("chat-a")!.queue.map((entry) => entry.id)).toEqual(["p1", "p2"]);
});

test("a chat left keeps its settled rows, drawn on its next select until its first window", async () => {
  const { rows, posts, drawn, feed } = source();
  await rows.choose("chat-a", HOLDS);
  feed(chat.get("window")!);
  feed(chat.get("ops")!);
  const shown = rows.view("chat-a")!;
  expect(shown.rows.at(-1)!.id).toBe("row-12");
  // One chat on the store a pane: choosing another closes it.
  await rows.choose("chat-b", HOLDS);
  expect(posts.filter((post) => post.method === "chat.rows.close").map((post) => post.params.sid)).toEqual(["rows.1"]);
  expect(rows.host.store.has("rows.1")).toBe(false);
  expect(rows.holds("chat-a")).toBe(false);
  expect(rows.view("chat-a")).toBeUndefined();

  // Reselected: drawn before any change, settled rows only (the open row 12 and the queue are not kept).
  expect(rows.drawKept("chat-a", HOLDS)).toBe(true);
  const kept = rows.view("chat-a")!;
  expect(kept.rows.map((row) => row.id)).toEqual(shown.rows.slice(0, -1).map((row) => row.id));
  expect(kept.queue).toEqual([]);
  expect(kept.canLoadOlder).toBe(false);
  // The rows it kept are the view rows it drew.
  expect(kept.rows[0]).toBe(shown.rows[0]);
  const calls = drawn.length;
  expect(await rows.choose("chat-a", HOLDS)).toBe(true);
  expect(rows.view("chat-a")).toBe(kept);
  feed(renamed(chat.get("window")!, "rows.3"));
  expect(drawn.length).toBe(calls + 1);
  const first = rows.view("chat-a")!;
  expect(first).not.toBe(kept);
  expect(first.rows.map((row) => row.id)).toEqual(Array.from({ length: 11 }, (_, n) => `row-${n + 1}`));
  // A chat has one kept thing: shown again, it keeps nothing until it is left.
  expect(rows.drawKept("chat-a", HOLDS)).toBe(false);
});

test(`at most ${KEPT_WINDOWS} chats keep a window, the least recently left going first`, async () => {
  const { rows, feed } = source();
  for (let n = 1; n <= KEPT_WINDOWS + 1; n += 1) {
    await rows.choose(`chat-${n}`, HOLDS);
    feed(renamed(chat.get("window")!, `rows.${n}`));
  }
  await rows.choose("chat-last", HOLDS);
  expect(rows.drawKept("chat-1", HOLDS)).toBe(false);
  for (let n = 2; n <= KEPT_WINDOWS + 1; n += 1) expect(rows.drawKept(`chat-${n}`, HOLDS)).toBe(true);
});

test("a fall sends the chat to v1 until another is chosen; the client's close closes it", async () => {
  const fallback = steps("fallback").get("upgrade")!;
  const { rows, posts, fell, feed, opens } = source();
  await rows.choose("chat-a", HOLDS);
  feed(chat.get("window")!);
  feed(fallback);
  expect(fell).toEqual([{ chat: "chat-a", code: "surface_off" }]);
  expect(rows.holds("chat-a")).toBe(false);
  expect(rows.view("chat-a")).toBeUndefined();
  // Per chat, not remembered: the chat stays v1, and the page still asks for the next one.
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(opens()).toBe(1);
  expect(chatRowsState()).toBe("on");
  expect(await rows.choose("chat-b", HOLDS)).toBe(true);
  expect(await rows.choose("chat-a", HOLDS)).toBe(true);
  expect(opens()).toBe(3);
  // The client's close: the chat on the store is closed and keeps its window.
  feed(renamed(chat.get("window")!, "rows.3"));
  rows.close();
  expect(posts.at(-1)).toEqual({ method: "chat.rows.close", params: { sid: "rows.3" } });
  expect(rows.drawKept("chat-a", HOLDS)).toBe(true);
});

test("a chat.rows.limit fall is that chat's alone", async () => {
  const { rows, fell, feed } = source();
  await rows.choose("chat-a", HOLDS);
  feed(chat.get("window")!);
  feed([JSON.stringify({ kind: "chatError", sid: "rows.1", method: "sub", id: null, code: "chat.rows.limit" })]);
  expect(fell).toEqual([{ chat: "chat-a", code: "chat.rows.limit" }]);
  expect(await rows.choose("chat-b", HOLDS)).toBe(true);
  feed(renamed(chat.get("window")!, "rows.2"));
  expect(rows.view("chat-b")!.rows.length).toBe(11);
});

test("the old bridge's unsupported is off for the document; the next select posts no open", async () => {
  const { rows, opens } = source((post) =>
    post.method === "chat.rows.open"
      ? Promise.reject(Object.assign(new Error("no"), { code: "unsupported" }))
      : undefined,
  );
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(chatRowsState()).toBe("off");
  expect(await rows.choose("chat-b", HOLDS)).toBe(false);
  expect(opens()).toBe(1);
});

test("an open refused with no code falls with chat.rows.lost and is not remembered", async () => {
  let refuse = true;
  const { rows, opens } = source((post) =>
    post.method === "chat.rows.open" && refuse ? Promise.reject(new Error("the link went")) : undefined,
  );
  const falls: string[] = [];
  const open = rows.host.open.bind(rows.host);
  rows.host.open = async (...args) => {
    const opened = await open(...args);
    if ("fallen" in opened) falls.push(opened.fallen);
    return opened;
  };
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(falls).toEqual([CHAT_ROWS_LOST]);
  expect(chatRowsState()).toBe("unknown");
  refuse = false;
  expect(await rows.choose("chat-b", HOLDS)).toBe(true);
  expect(opens()).toBe(2);
});

test("window.cmuxChatRows routes each change to its store and takes a batch once", async () => {
  const one = source(undefined, "one");
  const two = source(undefined, "two");
  await one.rows.choose("chat-a", HOLDS);
  await two.rows.choose("chat-b", HOLDS);
  const receiver = (globalThis as { cmuxChatRows?: { receive(event: unknown): void } }).cmuxChatRows!;
  expect(receiver).toBeDefined();
  // One batch with a window for each source's sid, and one for a sid neither holds.
  receiver.receive({
    batch: 7,
    changes: [
      ...renamed(chat.get("window")!, "one.1"),
      ...renamed(chat.get("window")!, "two.1"),
      ...renamed(chat.get("window")!, "gone.1"),
    ],
  });
  expect(one.rows.view("chat-a")!.rows.length).toBe(11);
  expect(two.rows.view("chat-b")!.rows.length).toBe(11);
  const taken = [...one.posts, ...two.posts].filter((post) => post.method === "chat.rows.taken");
  expect(taken).toEqual([{ method: "chat.rows.taken", params: { batch: 7 } }]);
  // A dropped client's sid is closed, and its changes are dropped after.
  two.rows.dispose();
  expect(two.posts.at(-1)).toEqual({ method: "chat.rows.close", params: { sid: "two.1" } });
  receiver.receive({ batch: 8, changes: renamed(chat.get("ops")!, "two.1") });
  const takenAfter = [...one.posts, ...two.posts].filter((post) => post.method === "chat.rows.taken");
  expect(takenAfter.map((post) => post.params.batch)).toEqual([7, 8]);
});

test("a batch is taken after the last client left the receiver", async () => {
  const one = source(undefined, "one");
  await one.rows.choose("chat-a", HOLDS);
  one.rows.dispose();
  const before = one.posts.length;
  receiveChatRows({ batch: 9, changes: renamed(chat.get("ops")!, "one.1") });
  expect(one.posts.slice(before)).toEqual([{ method: "chat.rows.taken", params: { batch: 9 } }]);
});

test("one store's throw leaves the other stores' changes applied and the batch taken once", async () => {
  const one = source(undefined, "one");
  const two = source(undefined, "two");
  await one.rows.choose("chat-a", HOLDS);
  await two.rows.choose("chat-b", HOLDS);
  one.rows.host.store.applyPart = () => {
    throw new Error("broken store");
  };
  expect(() =>
    receiveChatRows({
      batch: 10,
      changes: [...renamed(chat.get("window")!, "one.1"), ...renamed(chat.get("window")!, "two.1")],
    }),
  ).toThrow("broken store");
  expect(two.rows.view("chat-b")!.rows.length).toBe(11);
  const taken = [...one.posts, ...two.posts].filter((post) => post.method === "chat.rows.taken");
  expect(taken).toEqual([{ method: "chat.rows.taken", params: { batch: 10 } }]);
});

test("a chat whose first window does not come in time falls to v1 and its sid is closed", async () => {
  jest.useFakeTimers();
  const { rows, posts, fell, feed, opens } = source();
  expect(await rows.choose("chat-a", HOLDS)).toBe(true);
  jest.advanceTimersByTime(rows.firstWindowMs - 1);
  expect(fell).toHaveLength(0);
  jest.advanceTimersByTime(1);
  expect(fell).toEqual([{ chat: "chat-a", code: CHAT_ROWS_SLOW }]);
  expect(posts.at(-1)).toEqual({ method: "chat.rows.close", params: { sid: "rows.1" } });
  expect(rows.holds("chat-a")).toBe(false);
  // What comes for it after is dropped, and the chat stays v1 until another is chosen.
  feed(chat.get("window")!);
  expect(rows.view("chat-a")).toBeUndefined();
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(opens()).toBe(1);
  // A first window in time stops the deadline.
  expect(await rows.choose("chat-b", HOLDS)).toBe(true);
  feed(renamed(chat.get("window")!, "rows.2"));
  jest.advanceTimersByTime(rows.firstWindowMs * 2);
  expect(fell).toHaveLength(1);
  expect(rows.holds("chat-b")).toBe(true);
});

test("an open answered with another sid falls that chat once, counted, and the switch stays", async () => {
  let other = true;
  const { rows, opens } = source((post) =>
    post.method === "chat.rows.open" && other ? Promise.resolve({ sid: "theirs" }) : undefined,
  );
  expect(await rows.choose("chat-a", HOLDS)).toBe(false);
  expect(chatRowsOtherSids()).toBe(1);
  expect(chatRowsState()).toBe("unknown");
  other = false;
  expect(await rows.choose("chat-a", HOLDS)).toBe(true);
  expect(opens()).toBe(2);
});

test("a second choose of the chat whose open is out waits on that open, posting none", async () => {
  let answer = () => {};
  const gate = new Promise<void>((resolve) => (answer = resolve));
  const { rows, posts, opens } = source((post) =>
    post.method === "chat.rows.open" ? gate.then(() => ({ sid: post.params.sid })) : undefined,
  );
  const first = rows.choose("chat-a", HOLDS);
  const second = rows.choose("chat-a", HOLDS);
  answer();
  expect(await first).toBe(true);
  expect(await second).toBe(true);
  expect(opens()).toBe(1);
  expect(posts.some((post) => post.method === "chat.rows.close")).toBe(false);
  expect(rows.holds("chat-a")).toBe(true);
});
