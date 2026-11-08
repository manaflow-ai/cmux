import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import {
  draftsFrom,
  dropStashed,
  moveStash,
  readStashed,
  refreshStash,
  resetStashForTests,
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
  push: async (chat, text, attachments) => {
    if (refuse) throw new Error("refused");
    const row = { id: `stash-${++serial}`, text, attachments: [...attachments], at: serial };
    daemon.set(chat, [row, ...(daemon.get(chat) ?? [])].slice(0, 5));
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
