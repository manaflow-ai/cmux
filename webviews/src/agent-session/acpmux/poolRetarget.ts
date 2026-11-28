// A warm pool page's side of the chat page pool (CMUX-1005; rules in the Rust crate
// cmux-chat-page-pool, host in CEFChatPagePool.swift). The host calls `cmux.agent.pool.retarget`
// with the session a sidebar hover points at; the page switches the chat it shows without a
// reload, so a later click adopts a page that already drew that chat. The latest call wins: a
// retarget that lands while an earlier one is still switching supersedes it.
import { pageError, type PageClient } from "../../pages/shared/pageClient";
import { handleForPage } from "./paneView";

export const POOL_RETARGET_OP = "cmux.agent.pool.retarget";

export type Retarget = (session: string, signal: AbortSignal) => void | Promise<void>;

export type PoolPage = {
  /// The session this page last switched to (null: none yet).
  current(): string | null;
  /// Stops serving the op.
  dispose(): void;
};

export function parseRetarget(params: unknown): string {
  const session = (params as { session?: unknown } | null)?.session;
  if (typeof session !== "string" || session.length === 0 || session.length > 512)
    throw pageError(POOL_RETARGET_OP, "retarget takes { session: non-empty string }");
  return session;
}

/// Serves the retarget op on `page`, switching with `retarget`.
export function servePoolRetarget(page: PageClient, retarget: Retarget): PoolPage {
  let current: string | null = null;
  let inflight: AbortController | null = null;
  const stop = handleForPage(page, POOL_RETARGET_OP, async (params) => {
    const session = parseRetarget(params);
    if (session === current && !inflight) return { session, switched: false };
    inflight?.abort();
    const controller = new AbortController();
    inflight = controller;
    try {
      await retarget(session, controller.signal);
    } finally {
      if (inflight === controller) inflight = null;
    }
    if (controller.signal.aborted) return { session, switched: false, superseded: true };
    current = session;
    return { session, switched: true };
  });
  return { current: () => current, dispose: stop };
}
