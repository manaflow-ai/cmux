import { createContext, useContext } from "react";

/// One account a chat can run on: an acpmux route (`_acpmux/route/list`, routes.rs) that serves
/// the chat's harness family, such as a direct subscription, an API key, a subrouter or CodeRouter.
export type ChatAccount = { id: string; name: string; kind?: string };

/// A chat's accounts. `active` is the route bound to it and `scope` where that binding comes from
/// (`chat`, `workspace`, `family`, `global`); no `active` means the harness's own login.
export type ChatAccountList = { accounts: ChatAccount[]; active?: string; scope?: string };

/// The composer's Account menu reads and switches a chat's route through these. Only a pane on
/// this Mac's acpmux has them: acpmux refuses routes to Web and peer connections.
export type ChatAccounts = {
  list(sessionId: string): Promise<ChatAccountList>;
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
  return { accounts, ...(active ? { active } : {}), ...(scope ? { scope } : {}) };
}
