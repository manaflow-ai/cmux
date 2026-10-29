import { NextResponse, type NextRequest } from "next/server";
import {
  dropSession,
  findSession,
  fitToCookie,
  isAccountId,
  readSessions,
  saveSession,
  writeSessions,
  type SavedSession,
} from "../../account-sessions";

export type SessionTokens = { accessToken: string; refreshToken: string };

/** What the sign-in service says about one saved refresh token. */
export type SessionLookup = { status: "valid"; id: string; tokens: SessionTokens } | { status: "invalid" };

export type AccountsDependencies = {
  /** The vault key's source. Null turns the routes off. */
  secret: string | null;
  /** The browser's signed-in account, from the request's own session cookies. */
  currentSession(request: NextRequest): Promise<{ id: string; refreshToken: string } | null>;
  /** Refreshes a saved token. Throws when the service can't answer, so a slow service never signs anyone out. */
  lookup(refreshToken: string): Promise<SessionLookup>;
  /** Ends a saved session at the service. Best effort. */
  revoke(refreshToken: string): Promise<void>;
  now?: () => number;
};

type CurrentSession = { known: true; session: { id: string; refreshToken: string } | null } | { known: false };

const ACTIONS = ["save", "check", "switch", "forget", "forget-all"] as const;
type Action = (typeof ACTIONS)[number];

/**
 * The account chooser's routes, all same-origin POSTs from the sign-in page:
 *
 * - `save`: keep the browser's current session, so switching away keeps it.
 * - `check`: which saved accounts are still signed in; ended ones are dropped.
 * - `switch`: the tokens for one saved account, after the service confirms
 *   they are still that account's. The current session is kept first.
 * - `forget`: end one saved session and drop it (the chooser's remove).
 * - `forget-all`: end every saved session (an explicit sign-out).
 */
export function makeAccountsHandler(dependencies: AccountsDependencies) {
  const now = dependencies.now ?? Date.now;

  return async function POST(request: NextRequest, context: { params: Promise<{ action: string }> }): Promise<Response> {
    const { action } = await context.params;
    if (!ACTIONS.includes(action as Action)) return json({ error: "not_found" }, 404);
    if (!isSameOriginFetch(request)) return json({ error: "forbidden" }, 403);
    const secret = dependencies.secret;
    if (!secret) return json({ error: "unavailable" }, 503);

    const body = await readBody(request);
    const sessions = readSessions(request, secret);

    // The browser's own session, read once per request. A failed read is
    // "unknown", not "signed out": any saved token could be the browser's own,
    // so nothing is evicted or refreshed until the read succeeds.
    let currentLookup: Promise<CurrentSession> | null = null;
    const currentSession = () =>
      (currentLookup ??= dependencies.currentSession(request).then(
        (session): CurrentSession => ({ known: true, session }),
        (): CurrentSession => ({ known: false }),
      ));

    async function keepCurrent(list: SavedSession[]): Promise<SavedSession[]> {
      const lookup = await currentSession();
      const current = lookup.known ? lookup.session : null;
      const next = current ? saveSession(list, { id: current.id, refreshToken: current.refreshToken, savedAt: now() }) : list;
      // Newest first, so anything that doesn't fit in one cookie is the oldest.
      return fitToCookie(next, secret!);
    }

    // A session pushed off the end of the list, or replaced by a newer one
    // for the same account, would stay live with nothing left to reach it,
    // so it is ended too. Never the browser's own session, even if it
    // couldn't be kept in the list: that would sign the browser out.
    async function endEvicted(next: SavedSession[]): Promise<void> {
      const lookup = await currentSession();
      if (!lookup.known) return;
      const current = lookup.session;
      const kept = new Set(next.map((session) => session.refreshToken));
      const evicted = sessions.filter((session) => !kept.has(session.refreshToken) && session.refreshToken !== current?.refreshToken);
      await Promise.all(evicted.map((session) => dependencies.revoke(session.refreshToken).catch(() => {})));
    }

    function reply(payload: unknown, next: SavedSession[]) {
      const response = json(payload);
      if (!sameSessions(sessions, next)) writeSessions(response, request, next, secret!);
      return response;
    }

    switch (action as Action) {
      case "save": {
        const next = await keepCurrent(sessions);
        await endEvicted(next);
        return reply({ ok: true }, next);
      }

      case "check": {
        const next = await checkSessions(sessions, await currentSession(), dependencies);
        return reply({ signedIn: next.map((session) => session.id) }, next);
      }

      case "switch": {
        const accountId = body?.accountId;
        if (!isAccountId(accountId)) return json({ error: "bad_request" }, 400);
        const saved = findSession(sessions, accountId);
        if (!saved) return json({ status: "signed-out" });
        let result: SessionLookup;
        try {
          result = await dependencies.lookup(saved.refreshToken);
        } catch {
          return json({ status: "error" });
        }
        // The saved token must still be that same account's. Anything else is
        // dropped and never handed back.
        if (result.status !== "valid" || result.id !== accountId) {
          // A live token for someone else is ended, not just forgotten.
          if (result.status === "valid") await dependencies.revoke(saved.refreshToken).catch(() => {});
          return reply({ status: "signed-out" }, dropSession(sessions, accountId));
        }
        const next = fitToCookie(saveSession(await keepCurrent(sessions), { id: accountId, refreshToken: result.tokens.refreshToken, savedAt: now() }), secret);
        await endEvicted(next);
        const response = reply({ status: "ok", tokens: result.tokens }, next);
        response.headers.set("cache-control", "no-store");
        return response;
      }

      case "forget": {
        const accountId = body?.accountId;
        if (!isAccountId(accountId)) return json({ error: "bad_request" }, 400);
        const saved = findSession(sessions, accountId);
        if (saved) await dependencies.revoke(saved.refreshToken).catch(() => {});
        return reply({ ok: true }, dropSession(sessions, accountId));
      }

      case "forget-all": {
        // The browser's own session is left to the SDK's sign-out: ending it
        // here first would make that sign-out fail.
        const lookup = await currentSession();
        const current = lookup.known ? lookup.session : null;
        const others = sessions.filter((session) => session.refreshToken !== current?.refreshToken);
        await Promise.all(others.map((session) => dependencies.revoke(session.refreshToken).catch(() => {})));
        return reply({ ok: true }, []);
      }
    }
  };
}

/** Which saved sessions are still signed in, following rotated tokens. */
async function checkSessions(sessions: SavedSession[], lookup: CurrentSession, dependencies: AccountsDependencies): Promise<SavedSession[]> {
  // Unknown: leave every saved account as it is, and let a switch decide.
  if (!lookup.known) return sessions;
  const current = lookup.session;
  const checked = await Promise.all(
    sessions.map(async (session): Promise<SavedSession | null> => {
      // The browser's own session is signed in by definition, and a
      // refresh here would go through a separate app: if the service
      // rotated the token, the browser's copy would go stale.
      if (session.refreshToken === current?.refreshToken) return session;
      let result: SessionLookup;
      try {
        result = await dependencies.lookup(session.refreshToken);
      } catch {
        // The service did not answer: keep it, and let a switch decide.
        return session;
      }
      if (result.status !== "valid") return null;
      if (result.id !== session.id) {
        // Live but someone else's: end it rather than strand it.
        await dependencies.revoke(session.refreshToken).catch(() => {});
        return null;
      }
      // Follow a rotated refresh token, so the next switch uses the live one.
      return { ...session, refreshToken: result.tokens.refreshToken };
    }),
  );
  return checked.filter((session): session is SavedSession => session !== null);
}

/**
 * Only the sign-in page's own fetches. The browser sets Sec-Fetch-Site and no
 * page can forge it (an Origin comparison adds nothing, and behind dev
 * proxies the server's idea of its own origin is unreliable). A JSON body
 * also needs a preflight from any other origin.
 */
function isSameOriginFetch(request: NextRequest): boolean {
  if (request.headers.get("sec-fetch-site") !== "same-origin") return false;
  return (request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json");
}

async function readBody(request: NextRequest): Promise<Record<string, unknown> | null> {
  try {
    const value: unknown = await request.json();
    return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function sameSessions(a: SavedSession[], b: SavedSession[]): boolean {
  return a.length === b.length && a.every((entry, index) => entry.id === b[index].id && entry.refreshToken === b[index].refreshToken && entry.savedAt === b[index].savedAt);
}

function json(payload: unknown, status = 200): NextResponse {
  return NextResponse.json(payload, { status, headers: { "cache-control": "no-store" } });
}
