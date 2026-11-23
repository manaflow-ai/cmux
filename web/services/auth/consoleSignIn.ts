import type { checkRateLimit as vercelCheckRateLimit } from "@vercel/firewall";
import { NextRequest, NextResponse } from "next/server";
import {
  constantTimeEqual,
  type HandoffCodeStore,
  isCodeChallenge,
  issueHandoffCode,
  redeemHandoffCode,
} from "../../app/lib/handoff-codes";
import { requestHostname, STAGING_WEB_HOST } from "../../app/lib/native-callback";

/**
 * Sign in with cmux for the cmux Cloud console: an authorization code with
 * PKCE, never a token in a URL.
 *
 * 1. The console server (backend/apps/dashboard/src/lib/sign-in-flow.ts)
 *    keeps `state` and the PKCE verifier in its own HttpOnly cookie and sends
 *    the browser to GET /handler/console-sign-in with its client id, the state
 *    and the S256 challenge.
 * 2. That route (makeConsoleSignInAuthorizeHandler) sends a signed-out person
 *    through the normal sign-in and back, then issues a one-time code
 *    (app/lib/handoff-codes.ts) to the client's fixed redirect URI. The
 *    redirect URI is never read from the request.
 * 3. The console server posts the code, the verifier and its client secret to
 *    POST /handler/console-sign-in/token (makeConsoleSignInTokenHandler),
 *    which consumes the code and answers a fresh session in the response body.
 *
 * Each deployment issues only to its own console: production cmux.com to
 * console.cmux.dev, the staging deployment to console-staging.cmux.dev (as
 * native-callback.ts keeps staging apps off production). A client is also off
 * until its secret is configured on that deployment.
 */

export type ConsoleSignInClient = {
  readonly id: string;
  readonly redirectUri: string;
  /** The cmux.com host names that may issue to this client. */
  readonly issuerHosts: readonly string[];
  readonly secret: "production" | "staging";
};

export const CONSOLE_SIGN_IN_CLIENTS: readonly ConsoleSignInClient[] = [
  {
    id: "cmux-console",
    redirectUri: "https://console.cmux.dev/auth/handoff",
    issuerHosts: ["cmux.com"],
    secret: "production",
  },
  {
    id: "cmux-console-staging",
    redirectUri: "https://console-staging.cmux.dev/auth/handoff",
    issuerHosts: [STAGING_WEB_HOST],
    secret: "staging",
  },
];

export type ConsoleSignInSecrets = {
  readonly production?: string;
  readonly staging?: string;
};

const MIN_SECRET_LENGTH = 32;
const STATE_PATTERN = /^[A-Za-z0-9_-]{22,128}$/;
const MAX_TOKEN_BODY_BYTES = 8 * 1024;
const SESSION_LIFETIME_MS = 30 * 24 * 60 * 60 * 1000;
export const CONSOLE_SIGN_IN_PATH = "/handler/console-sign-in";

/** The client `clientId` names, when this host may issue to it and its secret is configured. */
export function consoleSignInClient(
  clientId: string | null | undefined,
  host: string,
  secrets: ConsoleSignInSecrets,
): (ConsoleSignInClient & { readonly secretValue: string }) | null {
  const client = CONSOLE_SIGN_IN_CLIENTS.find((candidate) => candidate.id === clientId);
  if (!client || !client.issuerHosts.includes(host)) return null;
  const secretValue = secrets[client.secret];
  if (!secretValue || secretValue.length < MIN_SECRET_LENGTH) return null;
  return { ...client, secretValue };
}

const noStoreHeaders = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
} as const;

/** One page for every refusal: nothing on it says which check failed. */
function failurePage(status: number): NextResponse {
  return new NextResponse(
    `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>Sign-in could not continue</title></head>
<body style="font-family: system-ui, -apple-system, sans-serif; max-width: 440px; margin: 15vh auto; padding: 0 24px; text-align: center">
  <h1 style="font-size: 22px; font-weight: 600">Sign-in could not continue</h1>
  <p style="color: #555; line-height: 1.5">Go back to the cmux Cloud console and choose Sign in with cmux again.</p>
</body>
</html>`,
    { status, headers: { ...noStoreHeaders, "Content-Type": "text/html; charset=utf-8" } },
  );
}

function redirect(location: string | URL): NextResponse {
  const response = NextResponse.redirect(location, 303);
  for (const [name, value] of Object.entries(noStoreHeaders)) response.headers.set(name, value);
  return response;
}

/**
 * The authorize route's Vercel Firewall rule. A deployment needs its own
 * CMUX_CONSOLE_SIGN_IN_RATE_LIMIT_ID (undefined otherwise, so the route refuses);
 * only a local run may fall back to the feedback rule.
 */
export function consoleSignInRateLimitId(
  env: { CMUX_CONSOLE_SIGN_IN_RATE_LIMIT_ID?: string; CMUX_FEEDBACK_RATE_LIMIT_ID?: string },
  deployed: boolean,
): string | undefined {
  if (env.CMUX_CONSOLE_SIGN_IN_RATE_LIMIT_ID) return env.CMUX_CONSOLE_SIGN_IN_RATE_LIMIT_ID;
  return deployed ? undefined : env.CMUX_FEEDBACK_RATE_LIMIT_ID;
}

type RateLimitDependencies = {
  checkRateLimit?: typeof vercelCheckRateLimit;
  isVercel?: () => boolean;
  rateLimitId?: string;
};

/** Vercel's durable limiter; a deployed route fails closed when it is missing or errors. */
async function isRateLimited(request: NextRequest, dependencies: RateLimitDependencies): Promise<boolean> {
  const onVercel = dependencies.isVercel?.() ?? process.env.VERCEL === "1";
  if (!onVercel) return false;
  if (!dependencies.rateLimitId || !dependencies.checkRateLimit) return true;
  try {
    const result = await dependencies.checkRateLimit(dependencies.rateLimitId, { request });
    return result.rateLimited || Boolean(result.error);
  } catch {
    return true;
  }
}

export type ConsoleSignInUser = { readonly id: string; readonly isAnonymous?: boolean };

export type ConsoleSignInAuthorizeDependencies = RateLimitDependencies & {
  store: HandoffCodeStore | null;
  secrets: ConsoleSignInSecrets;
  /** The person signed in on cmux.com in this request, or null. */
  currentUser: () => Promise<ConsoleSignInUser | null>;
  /** This deployment's public origin, for the sign-in redirect. */
  origin: (request: NextRequest) => string;
  now?: () => number;
};

export function makeConsoleSignInAuthorizeHandler(dependencies: ConsoleSignInAuthorizeDependencies) {
  return async function GET(request: NextRequest): Promise<NextResponse> {
    if (await isRateLimited(request, dependencies)) return failurePage(429);
    const params = request.nextUrl.searchParams;
    const client = consoleSignInClient(params.get("client_id"), requestHostname(request), dependencies.secrets);
    const state = params.get("state") ?? "";
    const challenge = params.get("code_challenge") ?? "";
    if (!client || !dependencies.store || !STATE_PATTERN.test(state) || !isCodeChallenge(challenge) || params.get("code_challenge_method") !== "S256") {
      console.warn("auth.console_sign_in.authorize_refused", { reason: "request" });
      return failurePage(400);
    }

    let user: ConsoleSignInUser | null;
    try {
      user = await dependencies.currentUser();
    } catch {
      return failurePage(503);
    }
    if (!user || user.isAnonymous === true) {
      // Back here with the same (validated) parameters after the normal sign-in.
      const self = new URL(CONSOLE_SIGN_IN_PATH, "https://cmux.invalid");
      self.searchParams.set("client_id", client.id);
      self.searchParams.set("state", state);
      self.searchParams.set("code_challenge", challenge);
      self.searchParams.set("code_challenge_method", "S256");
      const signIn = new URL("/handler/sign-in", dependencies.origin(request));
      signIn.searchParams.set("after_auth_return_to", `${self.pathname}${self.search}`);
      return redirect(signIn);
    }

    let code: string;
    try {
      code = await issueHandoffCode(dependencies.store, {
        clientId: client.id,
        redirectUri: client.redirectUri,
        userId: user.id,
        codeChallenge: challenge,
        now: new Date(dependencies.now?.() ?? Date.now()),
      });
    } catch {
      return failurePage(503);
    }
    const target = new URL(client.redirectUri);
    target.searchParams.set("code", code);
    target.searchParams.set("state", state);
    return redirect(target);
  };
}

export type ConsoleSignInSession = { readonly accessToken: string; readonly refreshToken: string };

export type ConsoleSignInTokenDependencies = {
  store: HandoffCodeStore | null;
  secrets: ConsoleSignInSecrets;
  /** A fresh session for the user, or null when the account cannot sign in. */
  mintSession: (userId: string, expiresInMillis: number) => Promise<ConsoleSignInSession | null>;
  now?: () => number;
};

function jsonResponse(status: number, body: Record<string, string>): NextResponse {
  return NextResponse.json(body, { status, headers: noStoreHeaders });
}

/** The body as text, or null past `limit` bytes; stops reading there (a chunked body has no Content-Length). */
async function readCapped(request: NextRequest, limit: number): Promise<string | null> {
  const reader = request.body?.getReader();
  if (!reader) return "";
  const decoder = new TextDecoder();
  let size = 0;
  let text = "";
  for (;;) {
    const chunk = await reader.read();
    if (chunk.done) break;
    size += chunk.value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    text += decoder.decode(chunk.value, { stream: true });
  }
  return text + decoder.decode();
}

async function readJsonBody(request: NextRequest): Promise<Record<string, unknown> | null> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) return null;
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (!Number.isFinite(declared) || declared > MAX_TOKEN_BODY_BYTES) return null;
  const text = await readCapped(request, MAX_TOKEN_BODY_BYTES);
  if (text === null) return null;
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

const field = (body: Record<string, unknown>, name: string): string => {
  const value = body[name];
  return typeof value === "string" ? value : "";
};

export function makeConsoleSignInTokenHandler(dependencies: ConsoleSignInTokenDependencies) {
  return async function POST(request: NextRequest): Promise<NextResponse> {
    // Server to server only: a browser always sends Origin on a cross-origin POST.
    if (request.headers.get("origin") !== null) return jsonResponse(400, { error: "invalid_request" });
    let body: Record<string, unknown> | null;
    try {
      body = await readJsonBody(request);
    } catch {
      body = null;
    }
    if (!body) return jsonResponse(400, { error: "invalid_request" });

    const client = consoleSignInClient(field(body, "client_id"), requestHostname(request), dependencies.secrets);
    // Compare even when the client is unknown, so the time taken says nothing about which.
    const secretOk = constantTimeEqual(client?.secretValue ?? "\u0000", field(body, "client_secret"));
    if (!client || !secretOk || !dependencies.store) {
      console.warn("auth.console_sign_in.token_refused", { reason: "client" });
      return jsonResponse(401, { error: "invalid_client" });
    }

    const codeVerifier = field(body, "code_verifier");
    const redirectUri = field(body, "redirect_uri");
    let redeemed: Awaited<ReturnType<typeof redeemHandoffCode>>;
    try {
      redeemed = await redeemHandoffCode(dependencies.store, {
        code: field(body, "code"),
        clientId: client.id,
        // The code is bound to the allowlisted URI it was issued to; a request naming another one fails.
        redirectUri,
        codeVerifier,
        now: new Date(dependencies.now?.() ?? Date.now()),
      });
    } catch {
      return jsonResponse(503, { error: "temporarily_unavailable" });
    }
    if (!redeemed.ok) {
      console.warn("auth.console_sign_in.token_refused", { reason: redeemed.reason });
      return jsonResponse(400, { error: "invalid_grant" });
    }

    let session: ConsoleSignInSession | null;
    try {
      session = await dependencies.mintSession(redeemed.userId, SESSION_LIFETIME_MS);
    } catch {
      return jsonResponse(503, { error: "temporarily_unavailable" });
    }
    if (!session) {
      console.warn("auth.console_sign_in.token_refused", { reason: "account" });
      return jsonResponse(400, { error: "invalid_grant" });
    }
    return jsonResponse(200, { access_token: session.accessToken, refresh_token: session.refreshToken });
  };
}
