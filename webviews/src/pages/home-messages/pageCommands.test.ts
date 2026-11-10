import { describe, expect, it, mock } from "bun:test";
import type { HomeConversation } from "../home-channels/types";
import type { ListModel } from "./list/model";
import { MessagesNav } from "./nav";
import {
  currentSelection,
  moveConversation,
  present,
  selectNumber,
  show,
  type PageCommandContext,
} from "./pageCommands";
import { addRecipient, EMPTY_DRAFT } from "./sheets/recipients";

function context(ids = ["a", "b", "c"]) {
  let snapshot = {
    selected: undefined as string | undefined,
    highlight: undefined as string | undefined,
    conversations: new Map(ids.map((id) => [id, { id } as HomeConversation])),
  };
  const store = {
    getSnapshot: () => snapshot as never,
    select: mock(async (id: string) => {
      snapshot = { ...snapshot, selected: id, highlight: undefined };
    }),
    openLink: mock(async (url: string) => {
      const [, conversation, message] = /conversation\/([^/]+)\/message\/(.+)$/.exec(url)!;
      snapshot = { ...snapshot, selected: conversation, highlight: message };
      return true;
    }),
    reloadInbox: mock(async () => {}),
  };
  const model = { pinned: [{ id: "a" }], rows: ids.slice(1).map((id) => ({ id })) } as unknown as ListModel;
  const nav = new MessagesNav();
  const ctx: PageCommandContext = { store, nav, model };
  return { ctx, store, nav };
}

describe("page commands", () => {
  it("shows a conversation, at a message, with a draft", async () => {
    const { ctx, store, nav } = context();
    expect(await show(ctx, { conversation: "b" })).toEqual({ shown: true });
    expect(store.select).toHaveBeenCalledWith("b");
    expect(await show(ctx, { conversation: "c", message: "m1", draft: "hello" })).toEqual({ shown: true });
    expect(store.openLink).toHaveBeenCalledWith("cmux://conversation/c/message/m1");
    expect(currentSelection(ctx)).toEqual({ conversation: "c", message: "m1" });
    expect(nav.draft("c")).toBe("hello");
    expect(nav.getSnapshot().draftEpoch).toBe(1);
  });

  it("refuses an unknown or malformed conversation", async () => {
    const { ctx, store } = context();
    expect(await show(ctx, { conversation: "zzz" })).toEqual({ shown: false });
    expect(store.reloadInbox).toHaveBeenCalled();
    expect(await show(ctx, { conversation: "../x" })).toEqual({ shown: false });
    expect(await show(ctx, null)).toEqual({ shown: false });
  });

  it("presents and closes sheets and New Message", () => {
    const { ctx, nav } = context();
    expect(present(ctx, { sheet: "requests" })).toEqual({ presented: true });
    expect(nav.getSnapshot().sheet).toEqual({ kind: "requests" });
    expect(present(ctx, { sheet: "invite", prefill: "a@b.co" })).toEqual({ presented: true });
    expect(nav.getSnapshot().sheet).toEqual({ kind: "invite", prefill: "a@b.co" });
    // Group Info needs a conversation: the named one, else the open one.
    expect(present(ctx, { sheet: "groupInfo" })).toEqual({ presented: false });
    expect(present(ctx, { sheet: "groupInfo", conversation: "b" })).toEqual({ presented: true });
    expect(present(ctx, { sheet: "nope" })).toEqual({ presented: false });
    expect(present(ctx, { sheet: "newMessage" })).toEqual({ presented: true });
    expect(nav.getSnapshot().sheet).toBeUndefined();
    expect(nav.getSnapshot().compose?.shown).toBe(true);
    expect(currentSelection(ctx)).toBeNull();
    expect(present(ctx, { sheet: "closeNewMessage" })).toEqual({ presented: true });
    expect(present(ctx, { sheet: "closeNewMessage" })).toEqual({ presented: false });
  });

  it("moves through the list in its order, wrapping, and selects by number", async () => {
    const { ctx, store } = context();
    await store.select("c");
    expect(await moveConversation(ctx, { delta: 1 })).toEqual({ moved: true });
    expect(store.select).toHaveBeenLastCalledWith("a");
    expect(await moveConversation(ctx, { delta: -1 })).toEqual({ moved: true });
    expect(store.select).toHaveBeenLastCalledWith("c");
    expect(await moveConversation(ctx, { delta: 0.5 })).toEqual({ moved: false });
    expect(await selectNumber(ctx, { number: 2 })).toEqual({ selected: true });
    expect(store.select).toHaveBeenLastCalledWith("b");
    expect(await selectNumber(ctx, { number: 9 })).toEqual({ selected: true });
    expect(store.select).toHaveBeenLastCalledWith("c");
    expect(await selectNumber(ctx, { number: 10 })).toEqual({ selected: false });
  });
});

describe("New Message draft", () => {
  it("drops an untouched draft when another conversation shows, keeps one with people", () => {
    const nav = new MessagesNav();
    nav.openCompose();
    nav.leaveCompose();
    expect(nav.getSnapshot().compose).toBeUndefined();
    nav.openCompose();
    nav.setComposeDraft(addRecipient(EMPTY_DRAFT, { kind: "address", address: { kind: "email", value: "a@b.co" } }));
    nav.leaveCompose();
    expect(nav.getSnapshot().compose?.shown).toBe(false);
    nav.openCompose();
    expect(nav.getSnapshot().compose?.draft.tokens).toHaveLength(1);
  });
});
