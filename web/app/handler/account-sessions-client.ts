// The browser side of the saved sessions (see account-sessions.ts). Every
// call goes through one queue: each route rewrites the whole cookie, so two
// at once would let the later one undo the earlier.

export type SwitchResult =
  | { status: "ok"; tokens: { accessToken: string; refreshToken: string } }
  | { status: "signed-out" }
  | { status: "error" };

let queue: Promise<unknown> = Promise.resolve();

// A stalled service must not leave a picked row spinning behind the queue.
const REQUEST_TIMEOUT_MS = 15_000;

function post(action: string, body: Record<string, unknown> = {}, keepalive = false): Promise<Response> {
  const run = () =>
    fetch(`/handler/accounts/${action}`, {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      keepalive,
      // A keepalive request outlives the page; it can't be timed out from it.
      signal: keepalive ? undefined : AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  const next = queue.then(run, run);
  queue = next.catch(() => {});
  return next;
}

/** Keeps the current session. Survives the page leaving right after. */
export function saveCurrentSession(): Promise<void> {
  return post("save", {}, true).then(() => undefined, () => undefined);
}

let checking: Promise<string[] | null> | null = null;

/**
 * The saved accounts that are still signed in, or null if that is unknown.
 * Callers at the same moment share one check.
 */
export function signedInAccounts(): Promise<string[] | null> {
  checking ??= checkSessions().finally(() => {
    checking = null;
  });
  return checking;
}

async function checkSessions(): Promise<string[] | null> {
  try {
    const response = await post("check");
    if (!response.ok) return null;
    const body = (await response.json()) as { signedIn?: unknown };
    return Array.isArray(body.signedIn) ? body.signedIn.filter((id): id is string => typeof id === "string") : null;
  } catch {
    return null;
  }
}

export async function switchSession(accountId: string): Promise<SwitchResult> {
  try {
    const response = await post("switch", { accountId });
    // Refused (a browser without fetch metadata) or turned off: there is no
    // saved session to use, so the pick signs in again instead of stopping.
    if (response.status === 403 || response.status === 404 || response.status === 503) return { status: "signed-out" };
    if (!response.ok) return { status: "error" };
    const body = (await response.json()) as { status?: unknown; tokens?: { accessToken?: unknown; refreshToken?: unknown } };
    if (body.status === "signed-out") return { status: "signed-out" };
    const accessToken = body.tokens?.accessToken;
    const refreshToken = body.tokens?.refreshToken;
    if (body.status === "ok" && typeof accessToken === "string" && typeof refreshToken === "string") {
      return { status: "ok", tokens: { accessToken, refreshToken } };
    }
    return { status: "error" };
  } catch {
    return { status: "error" };
  }
}

/** Ends one saved session (the chooser's remove). */
export function forgetSession(accountId: string): Promise<void> {
  return post("forget", { accountId }).then(() => undefined, () => undefined);
}

/**
 * Ends every saved session on this browser: part of an explicit sign-out,
 * before the SDK ends the current one. Tried twice; a sign-out still goes
 * ahead if both fail, since keeping someone signed in is worse. Use
 * `keepalive` when the page may leave before the answer comes back.
 */
export async function forgetAllSessions(options: { keepalive?: boolean } = {}): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const response = await post("forget-all", {}, options.keepalive === true);
      // 403 and 503 mean the routes never ran here, so nothing was saved.
      if (response.ok || response.status === 403 || response.status === 503) return;
    } catch {
      // try again
    }
  }
  console.error("[cmux sign-in] ending the other saved sessions failed");
}

/**
 * Makes saved tokens this browser's session through the SDK's own sign-in
 * step, so its cookies, cross-subdomain copies and caches stay its own
 * business. The step isn't public, so it is looked up rather than assumed:
 * without it the chooser falls back to signing in again.
 */
type TokenSignIn = (tokens: { accessToken: string; refreshToken: string }) => Promise<void>;

export function tokenSignIn(app: object): TokenSignIn | null {
  const step = (app as { _signInToAccountWithTokens?: unknown })._signInToAccountWithTokens;
  return typeof step === "function" ? (tokens) => (step as TokenSignIn).call(app, tokens) : null;
}
