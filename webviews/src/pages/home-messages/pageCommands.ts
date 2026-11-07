// What the app asks the Messages page (host → page over PageClient.handle; the host calls them with
// PageRouter.callPage), served while the page is mounted, and the one thing the page tells it back.
// A page without an op (an older build, or before it connected to its daemon) answers
// `cmux.protocol.unknown_op`; the host reads that as "no".
//
//   home.currentSelection     {}                                  -> {conversation, message?} | null
//   home.messages.show        {conversation, message?, draft?}    -> {shown}
//   home.messages.present     {sheet, conversation?, prefill?, requestedByAgent?} -> {presented}
//       sheet: newMessage | requests | groupInfo | newChief | invite | teamInvite | closeNewMessage
//   home.messages.focusComposer {}                                -> {focused}
//   home.moveConversation     {delta}                             -> {moved}    (as Channels serves it)
//   home.messages.selectNumber {number: 1..9}                     -> {selected} (9 = the last)
//   home.messages.attach | detach | quoteSelection                -> composerHandoff.ts
//   home.messages.recallHistory {older}                        -> {recalled}: Up or Down from outside the
//       page (the pane has the keyboard): the composer takes it and steps its history
//
// A plain Up or Down inside the page outside the box (and anything that keeps its arrows) does the
// same (composerHandoff.ts recallFromOutside).
//
// The page command `quoteSelection` (the app's selection menu, Quote in Reply) quotes the selected
// message text in the composer, as `home.messages.quoteSelection` does.
//
// Page → host: `cmux.home.messages.selected {conversation: string | null, message?}` on every
// change of the shown conversation (fire and forget): the host keeps it for its sync actions.
import { useEffect, useLayoutEffect, useRef } from "react";
import { CURRENT_SELECTION_OP, type HomeSelection } from "../home-channels/hostSelection";
import { MOVE_CONVERSATION_OP } from "../home-channels/hostMove";
import type { HomeChannelsStore } from "../home-channels/store";
import type { PageClient } from "../shared/pageClient";
import { PAGE_COMMAND, type PageCommand } from "../shared/pageStreams";
import { attach, detach, HandoffOps, quoteSelection, recallFromOutside } from "./composerHandoff";
import { conversationNumber, neighbor, type ListModel } from "./list/model";
import type { MessagesNav, SheetKind } from "./nav";

export const MessagesPageOps = {
  currentSelection: CURRENT_SELECTION_OP,
  show: "home.messages.show",
  present: "home.messages.present",
  focusComposer: "home.messages.focusComposer",
  moveConversation: MOVE_CONVERSATION_OP,
  selectNumber: "home.messages.selectNumber",
} as const;

/** Page → host: the shown conversation changed. */
export const SELECTED_OP = "cmux.home.messages.selected";

const SHEETS = new Set<string>(["requests", "groupInfo", "newChief", "invite", "teamInvite"]);
/** Conversation and message ids as the owners write them. */
const ID = /^[\w-]{1,200}$/;

type Json = Record<string, unknown>;
const record = (value: unknown): Json => (value && typeof value === "object" ? (value as Json) : {});
const id = (value: unknown): string | undefined => (typeof value === "string" && ID.test(value) ? value : undefined);

/** What the commands read and change, at call time. */
export interface PageCommandContext {
  store: Pick<HomeChannelsStore, "getSnapshot" | "select" | "openLink" | "reloadInbox">;
  nav: MessagesNav;
  /** The list as it shows now (search and filter applied). */
  model: ListModel;
}

/** The selection the host reads: none while New Message shows or nothing is open. */
export function currentSelection(context: PageCommandContext): HomeSelection | null {
  const { selected, highlight } = context.store.getSnapshot();
  if (!selected || context.nav.getSnapshot().compose?.shown) return null;
  return highlight ? { conversation: selected, message: highlight } : { conversation: selected };
}

/** Opens `conversation` as a click would: New Message steps aside, the composer takes the keyboard. */
async function open(context: PageCommandContext, conversation: string): Promise<void> {
  context.nav.leaveCompose();
  await context.store.select(conversation);
  context.nav.requestFocus();
}

export async function show(context: PageCommandContext, params: unknown): Promise<{ shown: boolean }> {
  const raw = record(params);
  const conversation = id(raw.conversation);
  if (!conversation) return { shown: false };
  const { store, nav } = context;
  if (!store.getSnapshot().conversations.has(conversation)) await store.reloadInbox();
  if (!store.getSnapshot().conversations.has(conversation)) return { shown: false };
  nav.leaveCompose();
  const message = id(raw.message);
  if (message) await store.openLink(`cmux://conversation/${conversation}/message/${message}`);
  else await store.select(conversation);
  const shown = store.getSnapshot().selected === conversation;
  if (shown && typeof raw.draft === "string") {
    nav.replaceDraft(conversation, raw.draft);
    nav.requestFocus();
  }
  return { shown };
}

export function present(context: PageCommandContext, params: unknown): { presented: boolean } {
  const raw = record(params);
  const { nav, store } = context;
  const sheet = raw.sheet;
  if (sheet === "closeNewMessage") return { presented: nav.closeCompose() };
  if (sheet === "newMessage") {
    nav.dismiss();
    nav.openCompose();
    nav.requestFocus();
    return { presented: true };
  }
  if (typeof sheet !== "string" || !SHEETS.has(sheet)) return { presented: false };
  const kind = sheet as SheetKind;
  const prefill = typeof raw.prefill === "string" ? raw.prefill : undefined;
  if (kind === "groupInfo") {
    const conversation = id(raw.conversation) ?? store.getSnapshot().selected;
    if (!conversation || !store.getSnapshot().conversations.has(conversation)) return { presented: false };
    nav.present({ kind, conversation, ...(raw.adding === true ? { adding: true } : {}) });
    return { presented: true };
  }
  nav.present({
    kind,
    ...(prefill !== undefined ? { prefill } : {}),
    ...(raw.requestedByAgent === true ? { requestedByAgent: true } : {}),
  });
  return { presented: true };
}

/** The shown conversation (none while New Message shows). */
const shownConversation = (context: PageCommandContext) =>
  context.nav.getSnapshot().compose?.shown ? undefined : context.store.getSnapshot().selected;

export async function moveConversation(context: PageCommandContext, params: unknown): Promise<{ moved: boolean }> {
  const delta = record(params).delta;
  if (typeof delta !== "number" || !Number.isInteger(delta) || delta === 0) return { moved: false };
  const target = neighbor(context.model, shownConversation(context), delta, true);
  if (!target) return { moved: false };
  await open(context, target);
  return { moved: true };
}

export async function selectNumber(context: PageCommandContext, params: unknown): Promise<{ selected: boolean }> {
  const number = record(params).number;
  if (typeof number !== "number" || !Number.isInteger(number) || number < 1 || number > 9) return { selected: false };
  const target = conversationNumber(context.model, number);
  if (!target) return { selected: false };
  await open(context, target);
  return { selected: true };
}

/** Serves every command on `host` with the context `latest` returns at call time. Returns the stop. */
export function servePageCommands(host: PageClient, latest: () => PageCommandContext): () => void {
  const stops = [
    host.handle(MessagesPageOps.currentSelection, () => currentSelection(latest())),
    host.handle(MessagesPageOps.show, (params) => show(latest(), params)),
    host.handle(MessagesPageOps.present, (params) => present(latest(), params)),
    host.handle(MessagesPageOps.focusComposer, () => ({ focused: latest().nav.focus() })),
    host.handle(MessagesPageOps.moveConversation, (params) => moveConversation(latest(), params)),
    host.handle(MessagesPageOps.selectNumber, (params) => selectNumber(latest(), params)),
    host.handle(HandoffOps.attach, (params) => attach(host, latest().nav.composer(), params)),
    host.handle(HandoffOps.detach, (params) => detach(latest().nav.composer(), params)),
    host.handle(HandoffOps.quoteSelection, () => quoteSelection(document, latest().nav.composer())),
    host.handle(HandoffOps.recallHistory, (params) => ({
      recalled:
        latest()
          .nav.composer()
          ?.recallHistory(record(params).older === false ? "newer" : "older") ?? false,
    })),
  ];
  const onKey = (event: KeyboardEvent) => void recallFromOutside(event, latest().nav.composer());
  document.addEventListener("keydown", onKey);
  stops.push(() => document.removeEventListener("keydown", onKey));
  // The app's menu on selected message text: Quote in Reply.
  let ended = false;
  let unsubscribe: (() => void) | undefined;
  void host
    .subscribe<PageCommand>(PAGE_COMMAND, (data) => {
      if (data?.command === "quoteSelection") quoteSelection(document, latest().nav.composer());
    })
    .then((stop) => {
      if (ended) stop();
      else unsubscribe = stop;
    })
    .catch(() => {});
  return () => {
    ended = true;
    unsubscribe?.();
    for (const stop of stops) stop();
  };
}

/** Serves the commands while the page is mounted, with the latest committed context, and tells the
 * host each change of the shown conversation. */
export function usePageCommands(host: PageClient | null, context: PageCommandContext, shown: HomeSelection | null) {
  const latest = useRef(context);
  useLayoutEffect(() => {
    latest.current = context;
  });
  useEffect(() => {
    if (!host) return;
    return servePageCommands(host, () => latest.current);
  }, [host]);
  const conversation = shown?.conversation ?? null;
  const message = shown?.message;
  useEffect(() => {
    if (!host) return;
    void host
      .call(SELECTED_OP, { conversation, ...(conversation && message ? { message } : {}) })
      .catch(() => undefined);
  }, [host, conversation, message]);
}
