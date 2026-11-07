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
//
// Page → host: `cmux.home.messages.selected {conversation: string | null, message?, composing?}` on
// every change of the shown conversation once the inbox is read (fire and forget): the host keeps it
// for its sync actions. `conversation: null` alone means nothing shows, so the host opens its
// default conversation; with `composing: true` New Message shows, which the host leaves alone.
import { useEffect, useLayoutEffect, useRef } from "react";
import { CURRENT_SELECTION_OP, type HomeSelection } from "../home-channels/hostSelection";
import { MOVE_CONVERSATION_OP } from "../home-channels/hostMove";
import type { HomeChannelsStore } from "../home-channels/store";
import type { PageClient } from "../shared/pageClient";
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

/** The requests a page remembers (a host retries within seconds; a few dozen cover any burst). */
const REMEMBERED_REQUESTS = 64;

/** The requests the page ran, by id, with their answers: one map for the page's life, so a request
 * retried across a reconnect's remount runs once too. */
const ranRequests = new Map<string, Promise<unknown>>();

/** Runs each host request once: the host asks again, with the same `request` id, when its try
 * timed out (HomeMessagesPage.ask), and a try that timed out may have run (a move that waited on
 * the transcript). A repeat gets the first run's answer. A call without an id always runs. */
export function once<T>(run: (params: unknown) => T | Promise<T>, ran: Map<string, Promise<unknown>> = ranRequests) {
  return (params: unknown): Promise<T> => {
    const request = record(params).request;
    if (typeof request !== "string" || !request) return Promise.resolve(run(params));
    const known = ran.get(request);
    if (known) return known as Promise<T>;
    const answer = Promise.resolve().then(() => run(params));
    ran.set(request, answer);
    if (ran.size > REMEMBERED_REQUESTS) ran.delete(ran.keys().next().value as string);
    return answer;
  };
}

/** Serves every command on `host` with the context `latest` returns at call time. Returns the stop. */
export function servePageCommands(host: PageClient, latest: () => PageCommandContext): () => void {
  const stops = [
    host.handle(MessagesPageOps.currentSelection, () => currentSelection(latest())),
    host.handle(
      MessagesPageOps.show,
      once((params) => show(latest(), params)),
    ),
    host.handle(
      MessagesPageOps.present,
      once((params) => present(latest(), params)),
    ),
    host.handle(MessagesPageOps.focusComposer, () => ({ focused: latest().nav.focus() })),
    host.handle(
      MessagesPageOps.moveConversation,
      once((params) => moveConversation(latest(), params)),
    ),
    host.handle(
      MessagesPageOps.selectNumber,
      once((params) => selectNumber(latest(), params)),
    ),
  ];
  return () => {
    for (const stop of stops) stop();
  };
}

/** The conversation the page reports as open: the store's selection while it is still listed (a
 * conversation that left the list, by Leave or Delete, is not), and none while New Message shows. */
export function reportedConversation(
  selected: string | undefined,
  listed: ReadonlyMap<string, unknown>,
  composing: boolean,
): string | undefined {
  return !composing && selected && listed.has(selected) ? selected : undefined;
}

/** What the page tells the host of what it shows (``SELECTED_OP``). */
export function selectedPayload(shown: HomeSelection | null, composing: boolean): Record<string, unknown> {
  const conversation = composing ? null : (shown?.conversation ?? null);
  return {
    conversation,
    ...(conversation && shown?.message ? { message: shown.message } : {}),
    ...(composing ? { composing: true } : {}),
  };
}

/** Serves the commands while the page is mounted, with the latest committed context, and tells the
 * host each change of the shown conversation, from when its inbox is read (`ready`): before that
 * "nothing shows" would only mean "not loaded yet". */
export function usePageCommands(
  host: PageClient | null,
  context: PageCommandContext,
  shown: HomeSelection | null,
  { composing, ready }: { composing: boolean; ready: boolean },
) {
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
    if (!host || !ready) return;
    const selection = conversation ? { conversation, ...(message ? { message } : {}) } : null;
    void host.call(SELECTED_OP, selectedPayload(selection, composing)).catch(() => undefined);
  }, [host, ready, conversation, message, composing]);
}

/** The page got the keyboard (the pane or tab took focus and the app gave it the page's web view,
 * `InternalPageView.focusTarget`): the message box takes it, as the native Home's primary input
 * did, unless something in the page already holds it (a field, a sheet). Returns the stop. */
export function followPageFocus(
  target: Pick<Window, "addEventListener" | "removeEventListener">,
  doc: Pick<Document, "activeElement" | "body">,
  nav: Pick<MessagesNav, "focus">,
): () => void {
  const focused = () => {
    const active = doc.activeElement;
    if (!active || active === doc.body) nav.focus();
  };
  target.addEventListener("focus", focused);
  return () => target.removeEventListener("focus", focused);
}
