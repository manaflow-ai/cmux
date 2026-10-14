// The pane's session list in keyset pages (cx-2lv1k). `_acpmux/watch` with `limit` answers the
// newest sessions and a `nextCursor`; `_acpmux/sessions` with that cursor answers the next page.
// The first page draws the pane and opens its chat; the rest arrive behind it, so a long list on
// a remote link never holds up the transcript. Search, project groups and pinned rows need every
// session, so the list is always read to the end. A daemon that ignores `limit` answers the whole
// list with no cursor, as before.

/** Sessions in one reply: the first page, and each later one. */
export const SESSION_PAGE = 200;

type Request = (method: string, params: Record<string, unknown>) => Promise<any>;
type Summary = { sessionId: string } & Record<string, any>;

export type SessionPage<S extends Summary> = { sessions: S[]; next?: string };

function pageOf<S extends Summary>(reply: any): SessionPage<S> {
  const sessions = (Array.isArray(reply?.sessions) ? reply.sessions : []).filter(
    (session: any): session is S => typeof session?.sessionId === "string" && session.sessionId !== "",
  );
  const next = typeof reply?.nextCursor === "string" && sessions.length > 0 ? reply.nextCursor : undefined;
  return { sessions, ...(next ? { next } : {}) };
}

/**
 * Reads the session list a page at a time. Starting a list again (a reconnect, a lagged watch)
 * or `stop` ends the pages of the one before. Sessions purged while pages load are remembered,
 * so a later page cannot bring one back; a session the pane already holds came from a newer
 * `session_changed` or an earlier page, so its copy stays.
 */
export class SessionPager<S extends Summary> {
  private run = 0;
  private purged = new Set<string>();

  constructor(private readonly request: Request) {}

  /** Turns the watch on and answers its first page. */
  async first(): Promise<SessionPage<S>> {
    const run = ++this.run;
    this.purged.clear();
    const page = pageOf<S>(await this.request("_acpmux/watch", { enabled: true, limit: SESSION_PAGE }));
    return run === this.run ? page : { sessions: page.sessions };
  }

  /** A `session_changed` purge seen while pages load. */
  purgedSession(sessionId: string): void {
    this.purged.add(sessionId);
  }

  /**
   * Reads every page after `cursor`, handing `add` the sessions the pane lacks. Answers false
   * when a newer list replaced this one. A page that fails falls back to the whole list at once.
   */
  async rest(cursor: string, held: () => S[], add: (sessions: S[]) => void): Promise<boolean> {
    const run = this.run;
    let next: string | undefined = cursor;
    while (next) {
      let page: SessionPage<S>;
      try {
        page = pageOf<S>(await this.request("_acpmux/sessions", { limit: SESSION_PAGE, cursor: next }));
      } catch {
        if (run !== this.run) return false;
        page = pageOf<S>(await this.request("_acpmux/sessions", {}));
        page = { sessions: page.sessions };
      }
      if (run !== this.run) return false;
      const known = new Set(held().map((session) => session.sessionId));
      const fresh = page.sessions.filter(
        (session) => !known.has(session.sessionId) && !this.purged.has(session.sessionId),
      );
      if (fresh.length > 0) add(fresh);
      next = page.next;
    }
    return true;
  }

  /** Ends the pages in flight. */
  stop(): void {
    this.run += 1;
  }
}
