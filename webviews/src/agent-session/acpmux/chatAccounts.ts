import { createContext, useContext } from "react";

/// One account a chat can run on: an acpmux route (`_acpmux/route/list`, routes.rs) that serves
/// the chat's harness family, such as a direct subscription, an API key, a subrouter or CodeRouter.
export type ChatAccount = { id: string; name: string; kind?: string };

/// A new local account, sent only through the native host.
export type NewChatAccount = {
  id: string;
  kind: string;
  family: string;
  name?: string;
  accountHome?: string;
  /// A Codex login in a shadow home: its own auth.json, the CLI's other files shared, so a chat
  /// moves between it and the CLI's own login in the same conversation.
  shadow?: boolean;
  secret?: string;
};

/// A chat's route choices and its active binding; no active route means the harness login.
export type ChatAccountList = {
  accounts: ChatAccount[];
  family?: string;
  active?: string;
  scope?: string;
  /// Every route's id, those of other families too: a new account's id must be none of them.
  ids?: string[];
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

/// A `_acpmux/route/list` reply as the chat's accounts. A route that says it does not serve the
/// chat's family is left out; an older acpmux names no `serves`, and then every route is listed.
export function readChatAccounts(reply: unknown): ChatAccountList {
  const raw = (reply && typeof reply === "object" ? reply : {}) as {
    routes?: unknown;
    family?: unknown;
    active?: { routeId?: unknown; scope?: unknown } | null;
  };
  const accounts: ChatAccount[] = [];
  const ids: string[] = [];
  for (const row of Array.isArray(raw.routes) ? raw.routes : []) {
    const route = row as { id?: unknown; name?: unknown; kind?: unknown; serves?: unknown } | null;
    if (typeof route?.id === "string") ids.push(route.id);
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
    ...(typeof raw.family === "string" && raw.family ? { family: raw.family } : {}),
    ...(active ? { active } : {}),
    ...(scope ? { scope } : {}),
    ...(ids.length ? { ids } : {}),
    ...(Array.isArray(raw.routes) ? {} : { unread: true as const }),
  };
}
