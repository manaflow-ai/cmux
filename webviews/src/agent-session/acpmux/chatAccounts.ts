import { createContext, useContext } from "react";
import { isModelRouterKind } from "./routerKinds";

/// One account a chat can run on: an acpmux route (`_acpmux/route/list`, routes.rs) that serves
/// the chat's harness family, such as a direct subscription, an API key, a subrouter or CodeRouter.
export type ChatAccount = { id: string; name: string; kind?: string };

/// A new local account, sent only through the native host.
export type NewChatAccount = {
  id: string;
  kind: string;
  name?: string;
  accountHome?: string;
  secret?: string;
};

/// A chat's route choices and its active binding; no active route means the harness login.
export type ChatAccountList = {
  accounts: ChatAccount[];
  active?: string;
  scope?: string;
  /// The reply carried no route list (an error or a shape this pane does not know): no routes known,
  /// which is not the same as none.
  unread?: true;
};

/// The composer's Account menu reads and switches a chat's route through these. Only a pane on
/// this Mac's acpmux has them: acpmux refuses routes to Web and peer connections.
export type ChatAccounts = {
  list(sessionId: string): Promise<ChatAccountList>;
  /** A local native gesture adds a route; it never changes the chat or default bindings. */
  add?(account: NewChatAccount): Promise<void>;
  /// `routeId` null puts the chat back on its default (workspace, family or global binding, else
  /// the harness login). acpmux restarts the harness on it and resumes the same session.
  set(sessionId: string, routeId: string | null): Promise<void>;
};

export const ChatAccountsContext = createContext<ChatAccounts | undefined>(undefined);

export const useChatAccounts = () => useContext(ChatAccountsContext);

/// What a failed turn can offer of CodeRouter (TurnRows.tsx TurnFailure): `"on"` when the chat runs on
/// a CodeRouter route already, the CodeRouter route that serves it when it has one, else undefined.
export function codeRouterOffer(list: ChatAccountList): ChatAccount | "on" | undefined {
  const isCodeRouter = (account: ChatAccount) => isModelRouterKind(account.kind);
  const active = list.accounts.find((account) => account.id === list.active);
  if (active && isCodeRouter(active)) return "on";
  return list.accounts.find(isCodeRouter);
}

/// A failed turn's CodeRouter action for `sessionId` (turnActions.ts `ownRoute`): what its routes
/// offer, and the move onto one, as the composer's Account menu moves it.
export const ownRouteOf = (accounts: ChatAccounts, sessionId: string) => ({
  // Routes this pane could not read offer nothing, rather than CodeRouter's setup.
  find: () =>
    accounts.list(sessionId).then((list) => {
      if (list.unread) throw new Error("acpmux.routesUnread");
      return codeRouterOffer(list);
    }),
  use: (routeId: string) => accounts.set(sessionId, routeId),
});

/// A `_acpmux/route/list` reply as the chat's accounts. A route that says it does not serve the
/// chat's family is left out; an older acpmux names no `serves`, and then every route is listed.
export function readChatAccounts(reply: unknown): ChatAccountList {
  const raw = (reply && typeof reply === "object" ? reply : {}) as {
    routes?: unknown;
    active?: { routeId?: unknown; scope?: unknown } | null;
  };
  const accounts: ChatAccount[] = [];
  for (const row of Array.isArray(raw.routes) ? raw.routes : []) {
    const route = row as { id?: unknown; name?: unknown; kind?: unknown; serves?: unknown } | null;
    if (typeof route?.id !== "string" || route.serves === false) continue;
    accounts.push({
      id: route.id,
      name: typeof route.name === "string" && route.name ? route.name : route.id,
      ...(typeof route.kind === "string" ? { kind: route.kind } : {}),
    });
  }
  const active = typeof raw.active?.routeId === "string" ? raw.active.routeId : undefined;
  const scope = typeof raw.active?.scope === "string" ? raw.active.scope : undefined;
  return {
    accounts,
    ...(Array.isArray(raw.kinds)
      ? { kinds: raw.kinds.filter((kind): kind is string => typeof kind === "string") }
      : {}),
    ...(active ? { active } : {}),
    ...(scope ? { scope } : {}),
    ...(Array.isArray(raw.routes) ? {} : { unread: true as const }),
  };
}
