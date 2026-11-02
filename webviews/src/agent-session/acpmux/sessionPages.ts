// The pane's session list in keyset pages (cx-2lv1k). `_acpmux/watch` with `limit` answers the
// newest sessions and a `nextCursor`; `_acpmux/sessions` with that cursor answers the next page.
// The first page draws the pane and opens its chat; the rest arrive behind it, so a long list on
// a remote link never holds up the transcript. Search, project groups and pinned rows need every
// session, so the list is always read to the end. A daemon that ignores `limit` answers the whole
// list with no cursor, as before, or (past its largest reply) its first rows and a cursor.

import { translate } from "./i18n";

/** Sessions in one reply: the first page, and each later one. */
export const SESSION_PAGE = 200;
/** Later pages one list reads at most (a million sessions) before reading the whole list instead. */
const MAX_PAGES = 5000;

type Request = (method: string, params: Record<string, unknown>) => Promise<any>;
type Summary = { sessionId: string } & Record<string, any>;

/** A protocol failure whose user-facing text is localized while the wire log keeps its detail. */
export class SessionPageError extends Error {
  constructor(readonly detail: string) {
    super(translate("error.connectFailed"));
    this.name = "SessionPageError";
  }
}

/** A page, and (a first page) the list it starts: its later pages end when a newer list starts.
 * `tab`: a chat on another machine's wire names the session that machine's daemon attached as the
 * tab's own (RemoteAcpmuxWire `tabSessionId`). */
export type SessionPage<S extends Summary> = { sessions: S[]; next?: string; run?: number; tab?: string };

function pageOf<S extends Summary>(reply: any): SessionPage<S> {
  const sessions = (Array.isArray(reply?.sessions) ? reply.sessions : []).filter(
    (session: any): session is S => typeof session?.sessionId === "string" && session.sessionId !== "",
  );
  // A page may contain no usable rows yet still have a continuation. The cursor
  // belongs to the daemon's page, independently of what the client can display.
  const next = typeof reply?.nextCursor === "string" ? reply.nextCursor : undefined;
  const tab = typeof reply?.tabSessionId === "string" && reply.tabSessionId ? reply.tabSessionId : undefined;
  return { sessions, ...(next !== undefined ? { next } : {}), ...(tab ? { tab } : {}) };
}

/**
 * A page of a whole-list read, held to what acpmux's own client holds it to (client.rs
 * `whole_list`): a cursor that is neither a string nor null, or a paged reply with no `sessions`,
 * is an error, never a short list. An empty page still names the rest.
 */
function wholePageOf<S extends Summary>(reply: any, after?: string): SessionPage<S> {
  const cursor = reply?.nextCursor;
  if (cursor !== undefined && cursor !== null && typeof cursor !== "string")
    throw new SessionPageError(
      // l10n-allow: diagnostic detail is wire-log only; SessionPageError.message is localized
      `acpmux gave the page cursor ${JSON.stringify(cursor)}`,
    );
  if ((after !== undefined || typeof cursor === "string") && !Array.isArray(reply?.sessions))
    throw new SessionPageError(
      // l10n-allow: diagnostic detail is wire-log only; SessionPageError.message is localized
      `the ${after === undefined ? "first page" : `page after cursor ${JSON.stringify(after)}`} lists no sessions`,
    );
  return { sessions: pageOf<S>(reply).sessions, ...(typeof cursor === "string" ? { next: cursor } : {}) };
}

/** acpmux's order (hub/session_pages.rs `sort_session_summaries`): newest first, then by
 * `sessionId`, then by `peer`, this daemon's own row (no `peer`) first. */
function newestFirst(a: Summary, b: Summary): number {
  const updated = (session: Summary) => (typeof session.updatedAt === "number" ? session.updatedAt : 0);
  const order = (x: string | undefined, y: string | undefined) =>
    x === y ? 0 : x === undefined ? -1 : y === undefined ? 1 : x < y ? -1 : 1;
  const peer = (session: Summary) => (typeof session.peer === "string" ? session.peer : undefined);
  return updated(b) - updated(a) || order(a.sessionId, b.sessionId) || order(peer(a), peer(b));
}

/**
 * Reads the session list a page at a time. Starting a list again (a reconnect, a lagged watch)
 * or `stop` ends the pages of the one before. Every `session_changed` since the list started is
 * remembered: a page read before it carries the older state, so `settle` lays the changes over
 * the pages, and `rest` never adds a session the pane already holds or one purged meanwhile.
 */
export class SessionPager<S extends Summary> {
  private run = 0;
  private purged = new Set<string>();
  private changed = new Map<string, S>();

  constructor(private readonly request: Request) {}

  /** Turns the watch on and answers its first page, or undefined when a newer list started meanwhile. */
  async first(): Promise<SessionPage<S> | undefined> {
    const run = ++this.run;
    this.purged.clear();
    this.changed.clear();
    const page = pageOf<S>(await this.request("_acpmux/watch", { enabled: true, limit: SESSION_PAGE }));
    return run === this.run ? { ...page, run } : undefined;
  }

  /**
   * The whole list, for a decision that cannot wait for the pages: watch without a `limit`, as
   * every host answers it (a remote pane's host never pages). A list past acpmux's largest reply
   * comes as its first rows and a `nextCursor`; the rest is read by `_acpmux/sessions` from it.
   */
  async whole(): Promise<S[]> {
    let page = wholePageOf<S>(await this.request("_acpmux/watch", { enabled: true }));
    const sessions = page.sessions;
    const seen = new Set<string>();
    for (let next = page.next; next !== undefined; next = page.next) {
      if (seen.has(next))
        throw new SessionPageError(
          // l10n-allow: diagnostic detail is wire-log only; SessionPageError.message is localized
          `acpmux gave the page cursor ${JSON.stringify(next)} twice`,
        );
      seen.add(next);
      page = wholePageOf<S>(await this.request("_acpmux/sessions", { cursor: next }), next);
      for (const session of page.sessions) sessions.push(session);
    }
    // The pages come in an order updates do not change (hash order), not newest first.
    return seen.size > 0 ? sessions.sort(newestFirst) : sessions;
  }

  /** A `session_changed` seen while the list loads. */
  changedSession(session: S): void {
    this.purged.delete(session.sessionId);
    this.changed.set(session.sessionId, session);
  }

  /** A `session_changed` purge seen while the list loads. */
  purgedSession(sessionId: string): void {
    this.changed.delete(sessionId);
    this.purged.add(sessionId);
  }

  /** `list` with every change since the list started laid over it, newest first as acpmux sorts. */
  settle(list: S[]): S[] {
    const kept = list.filter((session) => !this.purged.has(session.sessionId) && !this.changed.has(session.sessionId));
    return [...kept, ...this.changed.values()].sort(newestFirst);
  }

  /**
   * Reads every page after `first`, handing `add` the sessions the pane lacks. Answers false when
   * a newer list replaced the one `first` started. A page that fails, a cursor that comes back,
   * or a list past `MAX_PAGES` falls back to the whole list (`whole`); when that fails too, it throws.
   */
  async rest(first: SessionPage<S>, held: () => S[], add: (sessions: S[]) => void): Promise<boolean> {
    const run = first.run;
    let next = first.next;
    const seen = new Set<string>();
    // Keep an index of rows already held, instead of rescanning every prior page.
    // A session_changed during paging is covered by changed/purged below.
    const known = new Set(held().map((session) => session.sessionId));
    while (next !== undefined) {
      if (run !== this.run) return false;
      let page: SessionPage<S>;
      if (seen.has(next) || seen.size >= MAX_PAGES) page = { sessions: await this.whole() };
      else {
        seen.add(next);
        try {
          page = pageOf<S>(await this.request("_acpmux/sessions", { limit: SESSION_PAGE, cursor: next }));
        } catch {
          if (run !== this.run) return false;
          page = { sessions: await this.whole() };
        }
      }
      if (run !== this.run) return false;
      const fresh = page.sessions.filter(
        (session) =>
          !known.has(session.sessionId) &&
          !this.changed.has(session.sessionId) &&
          !this.purged.has(session.sessionId),
      );
      if (fresh.length > 0) {
        // Only learn IDs after filtering, preserving the previous behavior for duplicate
        // session IDs inside one page (for example, a local and a peer copy).
        for (const session of fresh) known.add(session.sessionId);
        add(fresh);
      }
      next = page.next;
    }
    return true;
  }

  /**
   * Every listed session's `usageStats` as acpmux reads them now, by session id. `usage: true` has
   * acpmux read each chat's harness records first (at most one pass every 5 s, waited for at most
   * 750 ms); without it a list carries the last pass's, or none when nothing asked since acpmux
   * started. Read a page at a time, as `rest`; a cursor that comes back or a list past
   * `MAX_PAGES` ends it with what came.
   */
  async usage(): Promise<Map<string, unknown>> {
    const found = new Map<string, unknown>();
    const seen = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = pageOf<S>(
        await this.request("_acpmux/sessions", { usage: true, limit: SESSION_PAGE, ...(cursor ? { cursor } : {}) }),
      );
      for (const session of page.sessions)
        if (session.usageStats !== undefined) found.set(session.sessionId, session.usageStats);
      cursor = page.next;
      if (cursor !== undefined && (seen.has(cursor) || seen.size >= MAX_PAGES)) break;
      if (cursor !== undefined) seen.add(cursor);
    } while (cursor !== undefined);
    return found;
  }

  /** Ends the pages in flight. */
  stop(): void {
    this.run += 1;
  }
}

/** Whether two `usageStats` read the same but for when acpmux read them. */
const sameBut = (a: unknown, b: unknown) =>
  typeof a === "object" &&
  a !== null &&
  typeof b === "object" &&
  b !== null &&
  JSON.stringify({ ...a, updatedAt: 0 }) === JSON.stringify({ ...b, updatedAt: 0 });

/**
 * `list` with each session's `usageStats` from `usage` (SessionPager.usage), the same array when
 * none changed. A session keeps the stats it holds when they are newer (a turn's end announced
 * them after the read began) or read the same but for `updatedAt` (nothing to draw again), and a
 * session `usage` does not name keeps its own.
 */
export function withUsage<S extends Summary>(list: S[], usage: ReadonlyMap<string, unknown>): S[] {
  const at = (stats: unknown) =>
    typeof (stats as { updatedAt?: unknown } | undefined)?.updatedAt === "number"
      ? (stats as { updatedAt: number }).updatedAt
      : -1;
  let changed = false;
  const next = list.map((session) => {
    const stats = usage.get(session.sessionId);
    if (stats === undefined || at(stats) <= at(session.usageStats) || sameBut(stats, session.usageStats))
      return session;
    changed = true;
    return { ...session, usageStats: stats };
  });
  return changed ? next : list;
}
