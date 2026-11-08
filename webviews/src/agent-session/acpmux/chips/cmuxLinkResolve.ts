// What a pasted cmux link names, read from the stores the page already keeps: a workspace, pane or
// tab from the host's places (cmuxLinkPlaces.ts), a chat from the session list's hover store
// (started/sessionHover.ts) by its acpmux id or its harness's own id. Nothing here asks per chip
// in a loop: every lookup is one map read, so a transcript of links costs the same however many
// workspaces and chats there are. A chat link the list does not have (a peer's, not mirrored yet)
// is asked of acpmux once per link and page (conversation/sessionRefs.ts), on idle.
import { useContext, useEffect, useMemo, useSyncExternalStore } from "react";
import { cmuxLinkTarget, namesChat, type CmuxLinkTarget } from "../conversation/cmuxLinks";
import {
  agentRef,
  knownSessionRef,
  resolveSessionRef,
  sessionRefsResolve,
  subscribeSessionRefs,
  whenIdle,
} from "../conversation/sessionRefs";
import { SessionHoverContext } from "../started/sessionHoverCardModel";
import type { SessionHoverStore } from "../started/sessionHover";
import { linkPlace, subscribeLinkPlaces } from "./cmuxLinkPlaces";

export type CmuxLinkKind = "chat" | "workspace" | "pane" | "tab";

/// What a link's chip draws: its kind, title and, for another machine's, the machine.
export type CmuxLinkInfo = {
  kind: CmuxLinkKind;
  title: string;
  host?: string;
  /// A tab's or pane's workspace, by its title.
  workspace?: string;
  /// The chat it opens: a chat link the list has, or one acpmux resolved.
  sessionId?: string;
};

/// The chat a chat link names in `store`, without asking anyone.
export function listedChat(target: CmuxLinkTarget, store: SessionHoverStore | undefined): string | undefined {
  if (!store) return undefined;
  if (target.kind === "session" || target.kind === "chief")
    return store.get(target.session) ? target.session : undefined;
  if (target.kind !== "agent") return undefined;
  if (target.harness && target.session) return store.byAgent(target.harness, target.session);
  // A web link that names the session alone: its acpmux id when the list has it.
  return target.session && store.get(target.session) ? target.session : undefined;
}

/// The chip of `target` from the page's stores, or undefined while nothing names it. `resolved` is
/// acpmux's answer for a chat the list does not have (`_acpmux/resolve`).
export function cmuxLinkInfo(
  target: CmuxLinkTarget,
  store: SessionHoverStore | undefined,
  resolved?: { sessionId: string; name?: string; host?: string } | null,
): CmuxLinkInfo | undefined {
  if (target.kind === "workspace" || target.kind === "pane" || target.kind === "tab") {
    const place = linkPlace(target.id);
    if (!place || place.kind !== target.kind) return undefined;
    return {
      kind: place.kind,
      title: place.title,
      ...(place.host && { host: place.host }),
      ...(place.workspace && { workspace: place.workspace }),
    };
  }
  if (!namesChat(target)) return undefined;
  const listed =
    listedChat(target, store) ?? (resolved && store?.get(resolved.sessionId) ? resolved.sessionId : undefined);
  if (listed && store) {
    const info = store.get(listed)!;
    const host = store.host(listed);
    return { kind: "chat", title: info.title, sessionId: listed, ...(host && { host }) };
  }
  // A chat acpmux found but this page does not list (a peer's): its name for the title, never its
  // id; the id is kept for the click, which opens it as the agent link did (CmuxLinkChip.tsx).
  if (resolved?.name)
    return {
      kind: "chat",
      title: resolved.name,
      sessionId: resolved.sessionId,
      ...(resolved.host && { host: resolved.host }),
    };
  return undefined;
}

const noStore = () => () => {};

/// The acpmux query a chat link the list does not have is resolved by, or undefined.
function resolveQuery(href: string, target: CmuxLinkTarget | undefined): string | undefined {
  if (!target || !namesChat(target) || !sessionRefsResolve()) return undefined;
  if (target.kind === "session" || target.kind === "chief") return target.session;
  const ref = agentRef(href);
  return ref?.kind === "link" ? ref.query : undefined;
}

/// What `href` names, live: a rename, a new chat in the list or a closed workspace redraws the chip.
/// `target` is undefined for text that is no cmux link; `info` undefined while nothing names it.
export function useCmuxLink(href: string): { target?: CmuxLinkTarget; info?: CmuxLinkInfo } {
  const target = useMemo(() => cmuxLinkTarget(href), [href]);
  const hover = useContext(SessionHoverContext);
  const store = hover?.store;
  const chat = target ? namesChat(target) : false;
  const listed = useSyncExternalStore(
    chat && store ? store.subscribe : noStore,
    () => (target && store ? listedChat(target, store) : undefined),
    () => (target && store ? listedChat(target, store) : undefined),
  );
  // Only a chat the list does not have is asked of acpmux, once per link and page.
  const query = chat && !listed ? resolveQuery(href, target) : undefined;
  const resolved = useSyncExternalStore(
    query ? subscribeSessionRefs : noStore,
    () => (query ? knownSessionRef(query) : undefined),
    () => (query ? knownSessionRef(query) : undefined),
  );
  useEffect(
    () => (query && resolved === undefined ? whenIdle(() => void resolveSessionRef(query)) : undefined),
    [query, resolved],
  );
  // A place reads the host's push; a chat its card (its title and machine) from the store.
  const placeKey = useSyncExternalStore(
    target && !chat ? subscribeLinkPlaces : noStore,
    () => (target && "id" in target && !chat ? linkPlace(target.id) : undefined),
    () => (target && "id" in target && !chat ? linkPlace(target.id) : undefined),
  );
  const card = useSyncExternalStore(
    chat && store ? store.subscribe : noStore,
    () => (listed && store ? store.get(listed) : undefined),
    () => (listed && store ? store.get(listed) : undefined),
  );
  const info = useMemo(
    () => (target ? cmuxLinkInfo(target, store, resolved) : undefined),
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- the stores' reads above are the deps.
    [target, store, listed, resolved, placeKey, card],
  );
  return { ...(target && { target }), ...(info && { info }) };
}

/// The page's chat list for code outside React (the draft's links, composer/deeplinkTitles.ts):
/// App.tsx sets it with the store it gives the transcript's cards.
let pageChats: SessionHoverStore | undefined;
export function setPageChats(store: SessionHoverStore | undefined): void {
  pageChats = store;
}
export function pageChatStore(): SessionHoverStore | undefined {
  return pageChats;
}

/// What `href` names from the page's stores, without asking anyone (the draft's links).
export function knownCmuxLink(href: string): CmuxLinkInfo | undefined {
  const target = cmuxLinkTarget(href);
  return target ? cmuxLinkInfo(target, pageChats) : undefined;
}

/// Runs `listener` when anything a link's chip reads changes: the chat list or the host's places.
export function subscribeCmuxLinks(listener: () => void): () => void {
  const store = pageChats;
  const offChats = store?.subscribe(listener);
  const offPlaces = subscribeLinkPlaces(listener);
  return () => {
    offChats?.();
    offPlaces();
  };
}
