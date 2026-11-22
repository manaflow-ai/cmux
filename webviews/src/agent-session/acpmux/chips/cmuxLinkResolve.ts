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
import type { SessionHoverInfo, SessionHoverStore } from "../started/sessionHover";
import { linkPlace, subscribeLinkPlaces, type CmuxLinkPlace } from "./cmuxLinkPlaces";

export type CmuxLinkKind = "chat" | "workspace" | "pane" | "tab";

/// The icon of each kind (the cmux pack's names), in the sent chip (CmuxLinkChip.tsx) and the draft's.
export const CMUX_LINK_ICONS: Record<CmuxLinkKind, string> = {
  chat: "agent.chat",
  workspace: "workspace",
  pane: "view.tab.trailing",
  tab: "view.tab.trailing",
};

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
  // A web link that names the session alone: the harness's own id (what `?session=` carries), or an
  // acpmux id when the list has one by it.
  if (!target.session) return undefined;
  return store.byAgentSession(target.session) ?? (store.get(target.session) ? target.session : undefined);
}

/// What a link's chip reads from the page's stores: the host's place it names, or the listed chat
/// it names with its card and machine. Passed in whole, never read inside ``cmuxLinkInfoFrom``, so
/// a cache keyed on its arguments (the React Compiler's, in ``useCmuxLink``) sees every change.
export type CmuxLinkReads = {
  place?: CmuxLinkPlace;
  /// The listed chat it names, by its acpmux id, and that chat's card and machine.
  listed?: string;
  card?: SessionHoverInfo;
  host?: string;
};

/// The listed chat `target` names in `store`: its own, else the one acpmux resolved it to.
function shownChat(
  target: CmuxLinkTarget,
  store: SessionHoverStore | undefined,
  resolved: { sessionId: string } | null | undefined,
): string | undefined {
  return listedChat(target, store) ?? (resolved && store?.get(resolved.sessionId) ? resolved.sessionId : undefined);
}

/// The chip of `target` from what it reads (``CmuxLinkReads``), or undefined while nothing names it.
/// `resolved` is acpmux's answer for a chat the list does not have (`_acpmux/resolve`). Pure: it
/// reads nothing but its arguments.
export function cmuxLinkInfoFrom(
  target: CmuxLinkTarget,
  reads: CmuxLinkReads,
  resolved?: { sessionId: string; name?: string; host?: string } | null,
): CmuxLinkInfo | undefined {
  if (target.kind === "workspace" || target.kind === "pane" || target.kind === "tab") {
    const place = reads.place;
    if (!place || place.kind !== target.kind) return undefined;
    return {
      kind: place.kind,
      title: place.title,
      ...(place.host && { host: place.host }),
      ...(place.workspace && { workspace: place.workspace }),
    };
  }
  if (!namesChat(target)) return undefined;
  if (reads.listed && reads.card)
    return { kind: "chat", title: reads.card.title, sessionId: reads.listed, ...(reads.host && { host: reads.host }) };
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

/// The chip of `target` from the page's stores now, or undefined while nothing names it (code
/// outside React; a component reads the stores with ``useCmuxLink``).
export function cmuxLinkInfo(
  target: CmuxLinkTarget,
  store: SessionHoverStore | undefined,
  resolved?: { sessionId: string; name?: string; host?: string } | null,
): CmuxLinkInfo | undefined {
  if (target.kind === "workspace" || target.kind === "pane" || target.kind === "tab")
    return cmuxLinkInfoFrom(target, { place: linkPlace(target.id) }, resolved);
  if (!namesChat(target)) return undefined;
  const listed = shownChat(target, store, resolved);
  const card = listed ? store?.get(listed) : undefined;
  const host = listed ? store?.host(listed) : undefined;
  return cmuxLinkInfoFrom(
    target,
    { ...(listed && { listed }), ...(card && { card }), ...(host && { host }) },
    resolved,
  );
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
  // Every store is read through a snapshot and handed to the pure ``cmuxLinkInfoFrom``: the React
  // Compiler caches a render's values by what they read, so a read of a module store or a store's
  // method in render would keep the first push's answer (review of #38166: a sent chip kept its old
  // title, or stayed the link, after a later push). A place is the host's push; a chat is the
  // listed one it names (its own or the one acpmux resolved it to), its card and its machine.
  const placeId = target && !chat && "id" in target ? target.id : undefined;
  const place = useSyncExternalStore(
    placeId ? subscribeLinkPlaces : noStore,
    () => (placeId ? linkPlace(placeId) : undefined),
    () => (placeId ? linkPlace(placeId) : undefined),
  );
  const shown = useSyncExternalStore(
    chat && store ? store.subscribe : noStore,
    () => (target && store ? shownChat(target, store, resolved) : undefined),
    () => (target && store ? shownChat(target, store, resolved) : undefined),
  );
  const card = useSyncExternalStore(
    shown && store ? store.subscribe : noStore,
    () => (shown && store ? store.get(shown) : undefined),
    () => (shown && store ? store.get(shown) : undefined),
  );
  const machine = useSyncExternalStore(
    shown && store ? store.subscribe : noStore,
    () => (shown && store ? store.host(shown) : undefined),
    () => (shown && store ? store.host(shown) : undefined),
  );
  const info = target
    ? cmuxLinkInfoFrom(
        target,
        {
          ...(place && { place }),
          ...(shown && { listed: shown }),
          ...(card && { card }),
          ...(machine && { host: machine }),
        },
        resolved,
      )
    : undefined;
  return { ...(target && { target }), ...(info && { info }) };
}

/// The page's chat list for code outside React (the draft's links, composer/deeplinkTitles.ts):
/// App.tsx sets it with the store it gives the transcript's cards. A draft that subscribed before
/// it was set, or before it was replaced, still hears it: ``subscribeCmuxLinks`` listens here, not
/// to the store it saw when it subscribed.
let pageChats: SessionHoverStore | undefined;
let offPageChats: (() => void) | undefined;
const linkListeners = new Set<() => void>();
const notifyLinks = () => {
  for (const listener of linkListeners) listener();
};
export function setPageChats(store: SessionHoverStore | undefined): void {
  if (store === pageChats) return;
  offPageChats?.();
  pageChats = store;
  offPageChats = store?.subscribe(notifyLinks);
  notifyLinks();
}
export function pageChatStore(): SessionHoverStore | undefined {
  return pageChats;
}

/// What `href` names from the page's stores, without asking anyone (the draft's links).
export function knownCmuxLink(href: string): CmuxLinkInfo | undefined {
  const target = cmuxLinkTarget(href);
  return target ? cmuxLinkInfo(target, pageChats) : undefined;
}

/// Runs `listener` when anything a link's chip reads changes: the page's chat list (whichever it is
/// now) or the host's places.
export function subscribeCmuxLinks(listener: () => void): () => void {
  linkListeners.add(listener);
  const offPlaces = subscribeLinkPlaces(listener);
  return () => {
    linkListeners.delete(listener);
    offPlaces();
  };
}
