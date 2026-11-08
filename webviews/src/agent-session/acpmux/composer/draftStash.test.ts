import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import {
  draftsFrom,
  dropStashed,
  moveStash,
  readStashed,
  refreshStash,
  resetStashForTests,
  retryMoves,
  setStashTransport,
  stashDraft,
  stashedNow,
  stashPreview,
  type StashTransport,
} from "./draftStash";

// acpmux's stash (stash.rs), in memory: a list's chips without contents, a get whole. `refuse`
// makes every push fail, as a refusal or a lost connection does.
type Row = { id: string; text: string; attachments: ComposerAttachment[]; at: number };
let daemon: Map<string, Row[]>;
let refuse = false;
let serial = 0;
const fake: StashTransport = {
  list: async (chat) => ({
    drafts: (daemon.get(chat) ?? []).map((row) => ({
      ...row,
      attachments: row.attachments.map(({ data: _data, ...chip }) => chip),
    })),
  }),
  push: async (chat, text, attachments, replaces) => {
    if (refuse) throw new Error("refused");
    const row = { id: `stash-${++serial}`, text, attachments: [...attachments], at: serial };
    const rest = (daemon.get(chat) ?? []).filter((entry) => entry.id !== replaces);
    daemon.set(chat, [row, ...rest].slice(0, 5));
    return { draft: { ...row, attachments: row.attachments.map(({ data: _data, ...chip }) => chip) } };
  },
  get: async (chat, id) => {
    const row = daemon.get(chat)?.find((entry) => entry.id === id);
    if (!row) throw new Error("no stashed draft with that id");
    return { draft: row };
  },
  drop: async (chat, id) => {
    daemon.set(
      chat,
      (daemon.get(chat) ?? []).filter((entry) => entry.id !== id),
    );
    return { removed: true };
  },
  // One write under acpmux's lock: the moved drafts on top, none twice, at most five; then the
  // source goes.
  move: async (chat, to) => {
    const kept = daemon.get(to) ?? [];
    const moving = (daemon.get(chat) ?? []).filter((row) => !kept.some((own) => own.id === row.id));
    daemon.set(to, [...moving, ...kept].slice(0, 5));
    daemon.delete(chat);
    return { moved: moving.length };
  },
};

beforeEach(() => {
  daemon = new Map();
  refuse = false;
  resetStashForTests(fake);
});
afterEach(() => resetStashForTests());

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AAA",
});
const texts = (chat: string) => stashedNow(chat).map((entry) => entry.text);

describe("draft stash", () => {
  test("a stash shows at once, newest first, and an empty draft is not stashed", async () => {
    expect(await stashDraft("chat", "  ", [])).toBe(false);
    expect(await stashDraft("chat", "first", [])).toBe(true);
    expect(await stashDraft("chat", "second", [image("a")])).toBe(true);
    expect(texts("chat")).toEqual(["second", "first"]);
    // The row's chip has no contents; the whole draft read back has them.
    expect(stashedNow("chat")[0]!.attachments[0]!.data).toBeUndefined();
    const whole = await readStashed("chat", stashedNow("chat")[0]!.id);
    expect(whole?.attachments.map((chip) => chip.data)).toEqual(["AAA"]);
  });

  test("a draft stays stashed until it is dropped", async () => {
    await stashDraft("chat", "kept", []);
    const id = stashedNow("chat")[0]!.id;
    expect((await readStashed("chat", id))?.text).toBe("kept");
    expect(daemon.get("chat")?.length).toBe(1);
    await dropStashed("chat", id);
    expect(texts("chat")).toEqual([]);
    expect(daemon.get("chat")).toEqual([]);
    expect(await readStashed("chat", id)).toBeUndefined();
  });

  test("a push in place of a taken draft lets no other go from a full stack", async () => {
    for (let index = 0; index < 5; index += 1) await stashDraft("chat", `draft ${index}`, []);
    const newest = stashedNow("chat")[0]!;
    expect(await stashDraft("chat", "typed meanwhile", [], newest.id)).toBe(true);
    expect(texts("chat")).toEqual(["typed meanwhile", "draft 3", "draft 2", "draft 1", "draft 0"]);
    expect(daemon.get("chat")?.map((row) => row.text)).toEqual(texts("chat"));
  });

  test("the page's stack holds at most five, as acpmux does", async () => {
    for (let index = 0; index < 6; index += 1) await stashDraft("chat", `draft ${index}`, []);
    expect(texts("chat")).toEqual(["draft 5", "draft 4", "draft 3", "draft 2", "draft 1"]);
  });

  test("another acpmux starts from no stacks, and the old one's late answers are dropped", async () => {
    await stashDraft("chat", "old machine's", []);
    let answer: (value: unknown) => void = () => undefined;
    setStashTransport({ ...fake, list: () => new Promise((resolve) => (answer = resolve)) });
    const late = refreshStash("chat");
    const other = { ...fake, list: async () => ({ drafts: [] }) };
    setStashTransport(other);
    expect(texts("chat")).toEqual([]);
    answer({ drafts: [{ id: "x", text: "late", attachments: [], at: 1 }] });
    await late;
    expect(texts("chat")).toEqual([]);
  });

  test("a draft acpmux does not take is not stashed", async () => {
    refuse = true;
    expect(await stashDraft("chat", "draft", [])).toBe(false);
    expect(texts("chat")).toEqual([]);
    resetStashForTests();
    expect(await stashDraft("chat", "no connection", [])).toBe(false);
  });

  test("a new page reads the stacks back from acpmux", async () => {
    await stashDraft("chat", "before the reload", [image("a")]);
    resetStashForTests(fake);
    expect(texts("chat")).toEqual([]);
    await refreshStash("chat");
    expect(texts("chat")).toEqual(["before the reload"]);
  });

  test("a new chat's stack follows it to its session, in order, and another new chat's stays", async () => {
    await stashDraft("new-a", "older", []);
    await stashDraft("new-a", "newer", [image("a")]);
    await stashDraft("new-b", "another new chat's", []);
    await moveStash("new-a", "session-1");
    expect(texts("new-a")).toEqual([]);
    expect(texts("session-1")).toEqual(["newer", "older"]);
    expect((await readStashed("session-1", stashedNow("session-1")[0]!.id))?.attachments[0]?.data).toBe("AAA");
    expect(texts("new-b")).toEqual(["another new chat's"]);
  });

  test("a move is one request, so the page never pushes or drops a draft of it itself", async () => {
    await stashDraft("new-a", "older", []);
    await stashDraft("new-a", "newer", []);
    const calls: string[] = [];
    setStashTransport({
      ...fake,
      push: (...args) => (calls.push("push"), fake.push(...args)),
      drop: (...args) => (calls.push("drop"), fake.drop(...args)),
      move: (...args) => (calls.push("move"), fake.move(...args)),
    });
    await moveStash("new-a", "session-1");
    expect(calls).toEqual(["move"]);
    expect(texts("session-1")).toEqual(["newer", "older"]);
    expect(texts("new-a")).toEqual([]);
  });

  test("a list read while a stash was out never takes the stash back; the stack is read again", async () => {
    const answers: ((value: unknown) => void)[] = [];
    setStashTransport({ ...fake, list: () => new Promise((resolve) => answers.push(resolve)) });
    const read = refreshStash("chat");
    expect(await stashDraft("chat", "fresh", [])).toBe(true);
    answers.shift()!({ drafts: [] });
    for (let turn = 0; turn < 5 && !answers.length; turn++) await Promise.resolve();
    expect(texts("chat")).toEqual(["fresh"]);
    answers.shift()!(await fake.list("chat"));
    await read;
    expect(texts("chat")).toEqual(["fresh"]);
  });

  test("a move acpmux does not take is tried again, and a failed drop shows the draft again", async () => {
    await stashDraft("new-a", "kept", []);
    let failing = true;
    setStashTransport({
      ...fake,
      move: async (chat, to) => {
        if (failing) throw new Error("lost the connection");
        return fake.move(chat, to);
      },
    });
    await moveStash("new-a", "session-1");
    expect(daemon.get("new-a")?.map((row) => row.text)).toEqual(["kept"]);
    expect(texts("new-a")).toEqual(["kept"]);
    failing = false;
    await retryMoves("session-1");
    expect(texts("session-1")).toEqual(["kept"]);
    expect(daemon.get("new-a")).toBeUndefined();
    // Done: shown again, the chat tries no move.
    failing = true;
    await retryMoves("session-1");
    expect(texts("session-1")).toEqual(["kept"]);
    // A drop acpmux does not take: the page reads the stack again and shows the draft.
    setStashTransport({
      ...fake,
      drop: async () => {
        throw new Error("refused");
      },
    });
    await refreshStash("session-1");
    const id = stashedNow("session-1")[0]!.id;
    expect(await dropStashed("session-1", id)).toBe(false);
    for (let turn = 0; turn < 5 && !texts("session-1").length; turn++) await Promise.resolve();
    expect(texts("session-1")).toEqual(["kept"]);
  });

  test("a move another acpmux answers stays waiting, and finishes on the first one's reconnect", async () => {
    await stashDraft("new-a", "kept", []);
    setStashTransport({
      ...fake,
      move: async () => {
        throw new Error("lost the connection");
      },
    });
    await moveStash("new-a", "session-1");
    // Another machine's acpmux: it holds nothing for the new chat and moves none.
    const elsewhere = new Map<string, Row[]>();
    setStashTransport({
      ...fake,
      list: async (chat) => ({ drafts: elsewhere.get(chat) ?? [] }),
      move: async () => ({ moved: 0 }),
    });
    await retryMoves("session-1");
    expect(daemon.get("new-a")?.map((row) => row.text)).toEqual(["kept"]);
    // The first acpmux again, on a new connection: the move finishes.
    setStashTransport({ ...fake });
    await retryMoves("session-1");
    expect(texts("session-1")).toEqual(["kept"]);
    expect(daemon.get("new-a")).toBeUndefined();
  });

  test("an answer that is not a stack reads as none", () => {
    expect(draftsFrom(undefined)).toEqual([]);
    expect(draftsFrom({ drafts: [{ id: 1 }, "x", null] })).toEqual([]);
  });

  test("the preview is one line", () => {
    expect(stashPreview({ id: "x", text: "line one\n\n  line   two", attachments: [], at: 0 })).toBe(
      "line one line two",
    );
  });
});
