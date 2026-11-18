// The chat menu's Show in Mini (Leo 2026-11-07: "we point it not necessarily at the chief, but at a
// particular coordinator chat and just have that say, like, okay, now you're technically the
// quote-unquote chief, at least for ... the display of the mini"). The host's mini shows the Chief or
// one chat: `agent.mini` answers `{ sessionId }` (null for the Chief) and `agent.mini.show
// { sessionId }` points it at a chat, or back at the Chief with null. The page asks when a chat opens,
// when its menu opens and after a pick; an app that does not answer (an older one) gets no row.
import { useEffect, useSyncExternalStore } from "react";
import { type Translate, translate } from "../i18n";
import { postNative } from "../native";
import type { ChatMenuItem } from "./chatHeaderToolsModel";

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;
let call: Call = postNative;

/// What the mini shows: a chat's session id, null for the Chief, undefined while unknown or unsupported.
let shown: string | null | undefined;
/// Each ask's number: only the newest answer is kept, so a slow read never undoes a later pick.
let asks = 0;
const listeners = new Set<() => void>();

function set(next: string | null | undefined): void {
  if (next === shown) return;
  shown = next;
  for (const listener of listeners) listener();
}

/// Tests replace the host; replacing it forgets the answer.
export function setChatMiniHost(next: Call | undefined): void {
  call = next ?? postNative;
  asks++;
  shown = undefined;
}

function parse(reply: unknown): string | null | undefined {
  if (!reply || typeof reply !== "object" || !("sessionId" in reply)) return undefined;
  const sessionId = (reply as { sessionId: unknown }).sessionId;
  if (sessionId === null) return null;
  return typeof sessionId === "string" && sessionId ? sessionId : undefined;
}

/// Asks the host what the mini shows. A refusal or an unreadable answer hides the row.
export function readChatMini(): Promise<void> {
  const ask = ++asks;
  return Promise.resolve()
    .then(() => call("agent.mini", {}))
    .then(
      (reply) => {
        if (ask === asks) set(parse(reply));
      },
      () => {
        if (ask === asks) set(undefined);
      },
    );
}

/// Points the mini at chat `sessionId`, or at the Chief with null, then reads what it shows now.
export function showInMini(sessionId: string | null): Promise<void> {
  asks++;
  return Promise.resolve()
    .then(() => call("agent.mini.show", { sessionId }))
    .then(
      () => readChatMini(),
      () => readChatMini(),
    );
}

/// What the mini shows now (read when the menu builds its rows).
export function chatMini(): string | null | undefined {
  return shown;
}

/// What the mini shows, redrawing on each answer; asks once per chat.
export function useChatMini(sessionId: string | undefined): string | null | undefined {
  const value = useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    () => shown,
  );
  useEffect(() => {
    if (sessionId) void readChatMini();
  }, [sessionId]);
  return value;
}

/// Show in Mini for a chat with a session; Show Chief in Mini once the mini shows this chat. No row
/// while the host has not answered `agent.mini`.
export function miniRow(
  chat: { sessionId: string | undefined; mini: string | null | undefined },
  show: (sessionId: string | null) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator">[] {
  const { sessionId, mini } = chat;
  if (!sessionId || mini === undefined) return [];
  if (mini === sessionId) {
    return [
      { key: "showChiefInMini", label: t("chatMenu.showChiefInMini"), icon: "agent.chief", onSelect: () => show(null) },
    ];
  }
  return [{ key: "showInMini", label: t("chatMenu.showInMini"), icon: "agent.chief", onSelect: () => show(sessionId) }];
}
