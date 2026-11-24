import { EncryptJWT, jwtDecrypt, jwtVerify, type JWTVerifyGetKey } from "jose";
import { canonicalizeEmailForMatching } from "../../../services/billing/emailMatching";

/**
 * Sign in with ChatGPT (OpenAI's OpenID Connect sign-in,
 * https://developers.openai.com/siwc/website). Hexclave (Stack Auth) has no
 * OpenAI provider and no custom OIDC providers, so cmux.com runs the flow
 * itself and then opens an ordinary Hexclave session for the matched account:
 * every later step (the app handoff, the account chooser, billing) stays the
 * same as for Google or GitHub.
 *
 * - Authorization Code with PKCE, a fresh state and nonce per start. The
 *   transaction is sealed (A256GCM) in an HttpOnly cookie, so the verifier
 *   never reaches the browser's JavaScript and nothing is stored server-side.
 * - The ID token is checked against OpenAI's JWKS: issuer, audience (our
 *   client ID), expiry, nonce and a non-empty `sub`.
 * - An account is keyed on issuer + client ID + `sub`, kept in the Hexclave
 *   user's server metadata. An email match alone never signs into an existing
 *   account: the person signs in with their usual method once, and the pending
 *   link (another sealed cookie) is attached then.
 */

export const CHATGPT_ISSUER = "https://auth.openai.com";
export const CHATGPT_AUTHORIZATION_ENDPOINT = "https://auth.openai.com/api/accounts/authorize";
export const CHATGPT_TOKEN_ENDPOINT = "https://auth.openai.com/api/accounts/oauth/token";
export const CHATGPT_JWKS_URI = "https://auth.openai.com/.well-known/jwks.json";

/** The provider id the sign-in form uses for "last used" and for the button. */
export const CHATGPT_PROVIDER_ID = "chatgpt";

export const CHATGPT_TRANSACTION_COOKIE = "cmux-chatgpt-signin";
export const CHATGPT_PENDING_LINK_COOKIE = "cmux-chatgpt-link";
export const CHATGPT_COOKIE_PATH = "/handler/chatgpt";
export const CHATGPT_TRANSACTION_TTL_MS = 10 * 60_000;
export const CHATGPT_PENDING_LINK_TTL_MS = 15 * 60_000;

const SCOPE = "openid profile email";
const CLOCK_TOLERANCE_SECONDS = 5;
const CONTINUE_PARAM = "cmux_continue";
const RETURN_PARAMS = ["after_auth_return_to", "web_return_to", "native_app_return_to"] as const;

/** Everything the flow needs from outside: OpenAI's client registration, keys, a clock and fetch. */
export type ChatGPTSignInSettings = {
  readonly clientId: string;
  /** Set for a confidential client (client_secret_basic); null for a public one. */
  readonly clientSecret: string | null;
  /** OpenAI's signing keys (`createRemoteJWKSet(CHATGPT_JWKS_URI)` in production). */
  readonly keys: JWTVerifyGetKey;
  /** 32 bytes that seal the transaction and pending-link cookies. */
  readonly sealKey: Uint8Array;
  readonly now: () => number;
  readonly fetch: (input: string, init?: RequestInit) => Promise<Response>;
};

/** The OpenAI identity a cmux account is linked to. */
export type ChatGPTLink = { readonly iss: string; readonly aud: string; readonly sub: string };

export type ChatGPTAccountUser = {
  readonly id: string;
  readonly primaryEmail: string | null;
  readonly primaryEmailVerified: boolean;
  readonly chatgpt: ChatGPTLink | null;
};

/** The account store (Hexclave in production). */
export interface ChatGPTAccounts {
  /** The account this browser is signed in to, if any. */
  currentUser(): Promise<ChatGPTAccountUser | null>;
  findByEmail(email: string): Promise<ChatGPTAccountUser | null>;
  /** Creates a verified-email account linked to `link`; "email-taken" when the email already signs in to another account. */
  create(input: { email: string; name: string | null; link: ChatGPTLink }): Promise<{ id: string } | "email-taken">;
  link(userId: string, link: ChatGPTLink): Promise<void>;
  /** Opens a session for `userId` in this browser. */
  signIn(userId: string): Promise<void>;
}

export type ChatGPTCallbackOutcome =
  | { readonly kind: "signed-in"; readonly returnTo: string }
  | { readonly kind: "link-required"; readonly redirect: string; readonly pendingLinkCookie: string }
  | { readonly kind: "cancelled"; readonly redirect: string }
  | { readonly kind: "failed"; readonly reason: string; readonly redirect: string };

type Transaction = { state: string; verifier: string; nonce: string; returnTo: string; exp: number };
type PendingLink = { link: ChatGPTLink; email: string; exp: number };

export function chatGPTRedirectURI(origin: string): string {
  return new URL(`${CHATGPT_COOKIE_PATH}/callback`, origin).toString();
}

/** Starts a sign-in: where to send the browser, and the sealed transaction for its cookie. */
export async function startChatGPTSignIn(
  settings: ChatGPTSignInSettings,
  input: { origin: string; returnTo: string | null },
): Promise<{ redirect: string; transactionCookie: string }> {
  const startedAt = settings.now();
  const transaction: Transaction = {
    state: randomToken(),
    verifier: randomToken(48),
    nonce: randomToken(),
    returnTo: sameOriginPath(input.returnTo, input.origin) ?? "/",
    exp: startedAt + CHATGPT_TRANSACTION_TTL_MS,
  };
  const url = new URL(CHATGPT_AUTHORIZATION_ENDPOINT);
  url.searchParams.set("client_id", settings.clientId);
  url.searchParams.set("redirect_uri", chatGPTRedirectURI(input.origin));
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("state", transaction.state);
  url.searchParams.set("code_challenge", await s256(transaction.verifier));
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("nonce", transaction.nonce);
  url.searchParams.set("ext_login_started_at_ms", String(startedAt));
  return { redirect: url.toString(), transactionCookie: await seal(settings, transaction) };
}

/** Finishes a sign-in at the callback. Never throws: every failure is an outcome. */
export async function finishChatGPTSignIn(
  settings: ChatGPTSignInSettings,
  accounts: ChatGPTAccounts,
  input: { origin: string; query: URLSearchParams; transactionCookie: string | null },
): Promise<ChatGPTCallbackOutcome> {
  const transaction = await unseal<Transaction>(settings, input.transactionCookie);
  if (!transaction || transaction.exp <= settings.now()) return failed("transaction", "/");
  const returnTo = transaction.returnTo;
  if (!timingSafeEqual(input.query.get("state") ?? "", transaction.state)) return failed("state", returnTo);

  const error = input.query.get("error");
  if (error) {
    if (error === "access_denied") return { kind: "cancelled", redirect: withoutContinue(returnTo) };
    return failed(`provider:${error}`, returnTo);
  }
  const code = input.query.get("code");
  if (!code) return failed("code", returnTo);

  let identity: Identity;
  try {
    identity = await redeem(settings, input.origin, code, transaction);
  } catch (caught) {
    console.error("[chatgpt sign-in] code redemption failed", caught instanceof Error ? caught.message : caught);
    return failed("token", returnTo);
  }
  if (!identity.email || identity.emailVerified !== true) {
    return failed("email-unverified", returnTo, "chatgpt-email-unverified");
  }

  try {
    const existing = await accounts.findByEmail(identity.email);
    if (existing) return await existingAccount(settings, accounts, existing, identity, returnTo);
    const created = await accounts.create({ email: identity.email, name: identity.name, link: identity.link });
    if (created === "email-taken") return await linkRequired(settings, identity, returnTo);
    await accounts.signIn(created.id);
    return { kind: "signed-in", returnTo };
  } catch (caught) {
    console.error("[chatgpt sign-in] account step failed", caught instanceof Error ? caught.message : caught);
    return failed("account", returnTo);
  }
}

/**
 * After the usual sign-in that a link needs: attaches the pending ChatGPT
 * identity when the signed-in account owns its verified email. Otherwise it
 * only continues.
 */
export async function finishChatGPTLink(
  settings: ChatGPTSignInSettings,
  accounts: ChatGPTAccounts,
  input: { origin: string; pendingLinkCookie: string | null; returnTo: string | null },
): Promise<{ linked: boolean; returnTo: string }> {
  const returnTo = sameOriginPath(input.returnTo, input.origin) ?? "/";
  const pending = await unseal<PendingLink>(settings, input.pendingLinkCookie);
  if (!pending || pending.exp <= settings.now()) return { linked: false, returnTo };
  const user = await accounts.currentUser();
  if (!user || user.chatgpt || !ownsEmail(user, pending.email)) return { linked: false, returnTo };
  await accounts.link(user.id, pending.link);
  return { linked: true, returnTo };
}

// MARK: Accounts

type Identity = { link: ChatGPTLink; email: string | null; emailVerified: boolean; name: string | null };

async function existingAccount(
  settings: ChatGPTSignInSettings,
  accounts: ChatGPTAccounts,
  user: ChatGPTAccountUser,
  identity: Identity,
  returnTo: string,
): Promise<ChatGPTCallbackOutcome> {
  if (user.chatgpt) {
    if (!sameLink(user.chatgpt, identity.link)) return failed("linked-elsewhere", returnTo);
    await accounts.signIn(user.id);
    return { kind: "signed-in", returnTo };
  }
  // Signed in already to this very account, with its email verified: the
  // person proved both sides, so linking needs no second sign-in.
  const current = await accounts.currentUser();
  if (current && current.id === user.id && ownsEmail(current, identity.email ?? "")) {
    await accounts.link(user.id, identity.link);
    await accounts.signIn(user.id);
    return { kind: "signed-in", returnTo };
  }
  return linkRequired(settings, identity, returnTo);
}

async function linkRequired(settings: ChatGPTSignInSettings, identity: Identity, returnTo: string): Promise<ChatGPTCallbackOutcome> {
  const pending: PendingLink = { link: identity.link, email: identity.email ?? "", exp: settings.now() + CHATGPT_PENDING_LINK_TTL_MS };
  const link = new URL(`${CHATGPT_COOKIE_PATH}/link`, "https://cmux.invalid");
  link.searchParams.set("return_to", returnTo);
  const target = new URL("/handler/auth-error", "https://cmux.invalid");
  target.searchParams.set("code", "chatgpt-link");
  target.searchParams.set("after_auth_return_to", `${link.pathname}${link.search}`);
  return { kind: "link-required", redirect: `${target.pathname}${target.search}`, pendingLinkCookie: await seal(settings, pending) };
}

function ownsEmail(user: ChatGPTAccountUser, email: string): boolean {
  return Boolean(
    email &&
      user.primaryEmail &&
      user.primaryEmailVerified &&
      canonicalizeEmailForMatching(user.primaryEmail) === canonicalizeEmailForMatching(email),
  );
}

function sameLink(a: ChatGPTLink, b: ChatGPTLink): boolean {
  return a.iss === b.iss && a.aud === b.aud && a.sub === b.sub;
}

// MARK: OpenAI

async function redeem(settings: ChatGPTSignInSettings, origin: string, code: string, transaction: Transaction): Promise<Identity> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    redirect_uri: chatGPTRedirectURI(origin),
    client_id: settings.clientId,
    code_verifier: transaction.verifier,
  });
  const headers: Record<string, string> = {
    "content-type": "application/x-www-form-urlencoded",
    accept: "application/json",
  };
  if (settings.clientSecret) {
    headers.authorization = `Basic ${btoa(`${encodeURIComponent(settings.clientId)}:${encodeURIComponent(settings.clientSecret)}`)}`;
  }
  const response = await settings.fetch(CHATGPT_TOKEN_ENDPOINT, { method: "POST", headers, body: body.toString(), cache: "no-store" });
  if (!response.ok) {
    const requestId = response.headers.get("openai-request-id") ?? response.headers.get("x-request-id") ?? "none";
    throw new Error(`token endpoint answered ${response.status} (request ${requestId})`);
  }
  const tokens = (await response.json()) as { id_token?: unknown };
  if (typeof tokens.id_token !== "string") throw new Error("token response has no id_token");

  const { payload } = await jwtVerify(tokens.id_token, settings.keys, {
    issuer: CHATGPT_ISSUER,
    audience: settings.clientId,
    algorithms: ["RS256"],
    clockTolerance: CLOCK_TOLERANCE_SECONDS,
    requiredClaims: ["sub", "exp", "iat"],
    currentDate: new Date(settings.now()),
  });
  if (typeof payload.nonce !== "string" || !timingSafeEqual(payload.nonce, transaction.nonce)) throw new Error("nonce mismatch");
  if (typeof payload.sub !== "string" || payload.sub.length === 0) throw new Error("empty sub");
  if ("sid" in payload && (typeof payload.sid !== "string" || payload.sid.length === 0)) throw new Error("bad sid");
  return {
    link: { iss: CHATGPT_ISSUER, aud: settings.clientId, sub: payload.sub },
    email: typeof payload.email === "string" && payload.email.includes("@") ? payload.email.trim() : null,
    emailVerified: payload.email_verified === true,
    name: typeof payload.name === "string" && payload.name.trim() ? payload.name.trim().slice(0, 200) : null,
  };
}

// MARK: Return targets

function failed(reason: string, returnTo: string, code = "chatgpt-failed"): ChatGPTCallbackOutcome {
  const target = new URL("/handler/auth-error", "https://cmux.invalid");
  target.searchParams.set("code", code);
  // "Back to sign in" keeps the original web or app sign-in going.
  const inner = new URL(returnTo, "https://cmux.invalid");
  for (const name of RETURN_PARAMS) {
    const value = inner.searchParams.get(name);
    if (value) target.searchParams.set(name, value);
  }
  return { kind: "failed", reason, redirect: `${target.pathname}${target.search}` };
}

function withoutContinue(returnTo: string): string {
  const url = new URL(returnTo, "https://cmux.invalid");
  url.searchParams.delete(CONTINUE_PARAM);
  return `${url.pathname}${url.search}`;
}

/** `value` as a path on `origin`, or null when it points anywhere else. */
export function sameOriginPath(value: string | null, origin: string): string | null {
  if (!value) return null;
  try {
    const base = new URL(origin);
    const url = new URL(value, base);
    if (url.origin !== base.origin) return null;
    return `${url.pathname}${url.search}`;
  } catch {
    return null;
  }
}

// MARK: Crypto

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomToken(bytes = 32): string {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

async function s256(verifier: string): Promise<string> {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length || a.length === 0) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}

async function seal(settings: ChatGPTSignInSettings, value: object): Promise<string> {
  return new EncryptJWT({ v: value }).setProtectedHeader({ alg: "dir", enc: "A256GCM" }).encrypt(settings.sealKey);
}

async function unseal<Value>(settings: ChatGPTSignInSettings, sealed: string | null): Promise<Value | null> {
  if (!sealed) return null;
  try {
    const { payload } = await jwtDecrypt(sealed, settings.sealKey, { currentDate: new Date(settings.now()) });
    return (payload.v as Value | undefined) ?? null;
  } catch {
    return null;
  }
}

/** The 32-byte cookie key, derived from a server secret so no new secret is needed. */
export async function deriveChatGPTSealKey(secret: string): Promise<Uint8Array> {
  const material = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), "HKDF", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: new TextEncoder().encode("cmux.com"), info: new TextEncoder().encode("chatgpt-sign-in-v1") },
    material,
    256,
  );
  return new Uint8Array(bits);
}
