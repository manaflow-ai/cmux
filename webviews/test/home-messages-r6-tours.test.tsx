// l10n-allow-file: test fixtures.
// The app's DEBUG verbs on the Messages page (debugCommands.ts): debug.home.sidebar_fixture's
// rows and look, debug.home's list and transcript read, debug.home.drive's list and transcript.
import { describe, expect, it, mock } from "bun:test";
import type { HomeConversation, HomeMessage } from "../src/pages/home-channels/types";
import {
  debugCommand,
  fixtureContacts,
  MessagesDebug,
  withFixture,
  type DebugContext,
  type DebugDom,
} from "../src/pages/home-messages/debugCommands";
import { listModel, type ListModel } from "../src/pages/home-messages/list/model";
import { MessagesNav } from "../src/pages/home-messages/nav";

const NOW = Date.UTC(2026, 10, 7, 12);
const words = {
  untitled: "Conversation",
  yesterday: "Yesterday",
  channel: "Channel",
  mentioned: "Mentioned",
  unread: (count: number) => `${count} unread`,
};
const strings = { language: "en", t: (key: string) => key, format: (key: string) => key };

function message(id: string, seq: number, text: string, extra: Partial<HomeMessage> = {}): HomeMessage {
  return {
    id,
    conversation: "real",
    seq,
    author: "other",
    createdAt: NOW,
    retracted: false,
    parts: [{ type: "text", text, mentions: [] }] as never,
    reactions: [],
    ...extra,
  };
}

function setup(options: { messages?: HomeMessage[] } = {}) {
  const real: HomeConversation = {
    id: "real",
    owner: "local",
    title: "Real",
    kind: "direct",
    participants: [
      { id: "me", kind: "human", name: "Me", chief: false },
      { id: "other", kind: "human", name: "Other", chief: false },
    ],
    lastSeq: 2,
    rev: 1,
    updatedAt: NOW,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
    lastAt: NOW,
  };
  let snapshot = {
    selected: "real" as string | undefined,
    conversations: new Map([["real", real]]),
    messages: options.messages ?? [],
    pending: [] as { conversation: string; text: string }[],
    typing: [] as string[],
    thread: undefined as string | undefined,
    threadStats: new Map(),
    highlight: undefined,
    inboxState: true,
    me: { id: "me", kind: "human", name: "Me", chief: false },
  };
  const store = {
    getSnapshot: () => snapshot as never,
    setPinned: mock(async () => true),
    setMarkedUnread: mock(async () => true),
    markConversationRead: mock(() => {}),
    openThread: mock(async (root: string | undefined) => {
      snapshot = { ...snapshot, thread: root };
    }),
  };
  const debug = new MessagesDebug();
  const nav = new MessagesNav();
  let focused = false;
  nav.setFocuser(() => (focused = true));
  const dom = {
    insertText: mock((_text: string) => focused),
    click: mock((_selector: string): ReturnType<DebugDom["click"]> => "clicked"),
    focusSearch: mock((_on: boolean) => true),
  };
  const setUnreadOnly = mock((_on: boolean) => {});
  const messages = {
    menu: mock(async () => [{ id: "home.chatColors", title: "Chat Colors…", action: "home.chatColors" }]),
    perform: mock(async () => {}),
  };
  const model = (): ListModel =>
    listModel(withFixture(snapshot.conversations, debug.getSnapshot()), { me: "me", now: NOW, language: "en", words });
  const context = (): DebugContext => ({
    store,
    nav,
    model: model(),
    messages,
    strings,
    debug,
    setUnreadOnly,
    dom,
    now: () => NOW,
  });
  return {
    context,
    debug,
    store,
    nav,
    dom,
    setUnreadOnly,
    messages,
    setSnapshot: (patch: object) => (snapshot = { ...snapshot, ...patch }),
  };
}

describe("debug.home.sidebar_fixture on the Messages page", () => {
  it("lists fixture conversations on the list only, the first ones pinned, after the real ones", async () => {
    const { context, debug } = setup();
    const answer = await debugCommand(context(), { action: "fixture", count: 5, pinned: 3 });
    expect(answer.rows).toEqual([
      "conv_fixture_0",
      "conv_fixture_1",
      "conv_fixture_2",
      "conv_fixture_3",
      "conv_fixture_4",
    ]);
    const model = context().model;
    expect(model.pinned.map((item) => item.id)).toEqual(["conv_fixture_0", "conv_fixture_1", "conv_fixture_2"]);
    expect(model.rows.map((item) => item.id)).toEqual(["real", "conv_fixture_3", "conv_fixture_4"]);
    expect(model.pinned[0]!.title).toBe("Austin");
    // A real conversation is never replaced; count 0 removes the fixture.
    await debugCommand(context(), { action: "fixture", count: 0 });
    expect(debug.getSnapshot().rows.size).toBe(0);
  });

  it("adds Chief DMs and channels, the first channel unread", async () => {
    const { context } = setup();
    await debugCommand(context(), {
      action: "fixture",
      count: 2,
      pinned: 0,
      chiefs: [{ id: "agent_x", name: "Scout" }],
      channels: ["Launch", "Design"],
      width: 340,
    });
    const model = context().model;
    const byId = new Map(model.rows.map((item) => [item.id, item]));
    expect(byId.get("conv_fixture_chief_0")?.conversation.kind).toBe("chief");
    expect(byId.get("conv_fixture_channel_0")?.title).toBe("Launch");
    expect(byId.get("conv_fixture_channel_0")?.unread).toBe(true);
    expect(byId.get("conv_fixture_channel_1")?.unread).toBe(false);
  });

  it("sets the list's look without reseeding the rows", async () => {
    const { context, debug, dom, setUnreadOnly } = setup();
    await debugCommand(context(), { action: "fixture", count: 6, pinned: 2 });
    const before = debug.getSnapshot().rows;
    await debugCommand(context(), { action: "fixture", width: 320, select: 0 });
    expect(debug.getSnapshot().rows).toBe(before);
    expect(debug.getSnapshot().width).toBe(320);
    expect(debug.getSnapshot().selected).toBe("conv_fixture_0");
    await debugCommand(context(), { action: "fixture", search: true });
    expect(dom.focusSearch).toHaveBeenLastCalledWith(true);
    await debugCommand(context(), { action: "fixture", unread: true });
    expect(setUnreadOnly).toHaveBeenLastCalledWith(true);
    expect(await debugCommand(context(), { action: "fixture", select: 99 })).toEqual({ error: "no such row" });
  });

  it("opens New Message with the fixture Chiefs and teammates", async () => {
    const { context, debug, nav } = setup();
    const answer = await debugCommand(context(), { action: "fixture", new_message: 3 });
    expect(answer).toEqual({ rows: 7 });
    expect(nav.getSnapshot().compose?.shown).toBe(true);
    expect(
      debug
        .getSnapshot()
        .contacts?.filter((c) => c.source === "team")
        .map((c) => c.name),
    ).toEqual(["Austin", "Lucas Wang", "Aziz Ali"]);
    expect(fixtureContacts(0).every((c) => c.source === "agent")).toBe(true);
  });

  it("shows an intro on the shown Chief", async () => {
    const { context, debug } = setup();
    expect(await debugCommand(context(), { action: "fixture", intro: "askFocus" })).toEqual({ intro: false });
    expect(debug.getSnapshot().intro).toBe("askFocus");
  });
});

describe("debug.home's Messages list and transcript", () => {
  it("reports the list as drawn and the shown transcript's tail", async () => {
    const { context, setSnapshot } = setup({ messages: [message("m1", 1, "hello"), message("m2", 2, "world")] });
    setSnapshot({ pending: [{ conversation: "real", text: "sending" }] });
    const answer = await debugCommand(context(), { action: "snapshot" });
    expect(answer.list).toEqual([{ id: "real", title: "Real", pinned: false, unread: false, chief: false }]);
    expect(answer.shown).toBe("real");
    expect(answer.transcript_tail).toEqual(["hello", "world", "sending"]);
    expect(answer.open_thread).toBeNull();
  });
});

describe("debug.home.drive on the Messages page", () => {
  it("runs the row menu's handlers", async () => {
    const { context, store, messages } = setup();
    expect(await debugCommand(context(), { action: "list", op: "pin", conversation: "real" })).toEqual({ ok: true });
    expect(store.setPinned).toHaveBeenCalledWith("real", true);
    await debugCommand(context(), { action: "list", op: "unread", conversation: "real" });
    expect(store.setMarkedUnread).toHaveBeenCalledWith("real", true);
    await debugCommand(context(), { action: "list", op: "read", conversation: "real" });
    expect(store.markConversationRead).toHaveBeenCalledWith("real");
    const menu = await debugCommand(context(), { action: "list", op: "menu", conversation: "real" });
    expect(menu.items).toEqual(["sidebar.menu.pin", "sidebar.menu.markUnread", "Chat Colors…"]);
    await debugCommand(context(), { action: "list", op: "menu", conversation: "real", item: "Chat Colors…" });
    expect(messages.perform).toHaveBeenCalled();
    expect((await debugCommand(context(), { action: "list", op: "pin", conversation: "nope" })).ok).toBe(false);
  });

  it("focuses, types and sends through the composer, and refuses an empty send", async () => {
    const { context, dom } = setup();
    expect(await debugCommand(context(), { action: "drive", drive: "focus" })).toEqual({ ok: true });
    expect(await debugCommand(context(), { action: "drive", drive: "type", text: "hi" })).toEqual({ ok: true });
    expect(dom.insertText).toHaveBeenCalledWith("hi");
    expect(await debugCommand(context(), { action: "drive", drive: "send" })).toEqual({ ok: true });
    expect(dom.click).toHaveBeenCalledWith(".hm-detail .mt-send");
    dom.click.mockImplementation(() => "missing");
    expect(await debugCommand(context(), { action: "drive", drive: "send" })).toEqual({ ok: false, refused: "empty" });
  });

  it("reads texts and typing, opens and closes threads", async () => {
    const { context, setSnapshot } = setup({
      messages: [
        message("root", 1, "root"),
        message("r1", 2, "reply", { threadRoot: "root" }),
        message("m3", 3, "last"),
      ],
    });
    expect((await debugCommand(context(), { action: "drive", drive: "texts" })).texts).toEqual([
      "root",
      "reply",
      "last",
    ]);
    expect((await debugCommand(context(), { action: "drive", drive: "typing" })).ok).toBe(false);
    setSnapshot({ typing: ["other"] });
    expect((await debugCommand(context(), { action: "drive", drive: "typing" })).ok).toBe(true);
    expect((await debugCommand(context(), { action: "drive", drive: "thread" })).open_thread).toBe("root");
    expect((await debugCommand(context(), { action: "drive", drive: "escape" })).open_thread).toBeNull();
    expect((await debugCommand(context(), { action: "drive", drive: "reply" })).open_thread).toBe("m3");
    expect((await debugCommand(context(), { action: "drive", drive: "thread_state" })).open_thread).toBe("m3");
  });

  it("answers no conversation when none shows", async () => {
    const { context, setSnapshot } = setup();
    setSnapshot({ selected: undefined });
    expect(await debugCommand(context(), { action: "drive", drive: "texts" })).toEqual({
      error: "no Home conversation is shown",
    });
  });
});
