import { KnownErrors } from "@hexclave/shared";
import { createRemoteJWKSet } from "jose";
import { NextRequest, NextResponse } from "next/server";
import { env } from "../../env";
import { requestOrigin } from "../../lib/request-origin";
import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { canonicalizeEmailForMatching } from "../../../services/billing/emailMatching";
import {
  CHATGPT_COOKIE_PATH,
  CHATGPT_JWKS_URI,
  CHATGPT_PENDING_LINK_COOKIE,
  CHATGPT_PENDING_LINK_TTL_MS,
  CHATGPT_TRANSACTION_COOKIE,
  CHATGPT_TRANSACTION_TTL_MS,
  deriveChatGPTSealKey,
  finishChatGPTLink,
  finishChatGPTSignIn,
  startChatGPTSignIn,
  type ChatGPTAccountUser,
  type ChatGPTAccounts,
  type ChatGPTLink,
  type ChatGPTSignInSettings,
} from "./chatgpt-sign-in";

/** The Hexclave user's server metadata key holding the linked ChatGPT identity. */
const METADATA_KEY = "cmuxChatGPT";
const SESSION_EXPIRES_IN_MS = 365 * 24 * 60 * 60 * 1000;
const TOKEN_TIMEOUT_MS = 10_000;

const keys = createRemoteJWKSet(new URL(CHATGPT_JWKS_URI));
let sealKey: Promise<Uint8Array> | null = null;

async function settings(): Promise<ChatGPTSignInSettings | null> {
  const clientId = env.CMUX_CHATGPT_SIGNIN_CLIENT_ID;
  const secret = env.STACK_SECRET_SERVER_KEY;
  if (!clientId || !secret || !isStackConfigured()) return null;
  sealKey ??= deriveChatGPTSealKey(secret);
  return {
    clientId,
    clientSecret: env.CMUX_CHATGPT_SIGNIN_CLIENT_SECRET ?? null,
    keys,
    sealKey: await sealKey,
    now: () => Date.now(),
    // The token exchange waits at most 10 s, so a stalled OpenAI never holds the callback open.
    fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(TOKEN_TIMEOUT_MS) }),
  };
}

type ServerUserLike = {
  id: string;
  primaryEmail: string | null;
  primaryEmailVerified: boolean;
  isAnonymous?: boolean;
  serverMetadata: unknown;
  update(options: { serverMetadata: unknown }): Promise<void>;
  createSession(options: { expiresInMillis: number }): Promise<{ getTokens(): Promise<{ accessToken: string | null; refreshToken: string | null }> }>;
};

function linkOf(metadata: unknown): ChatGPTLink | null {
  if (typeof metadata !== "object" || metadata === null) return null;
  const value = (metadata as Record<string, unknown>)[METADATA_KEY];
  if (typeof value !== "object" || value === null) return null;
  const { iss, aud, sub } = value as Record<string, unknown>;
  return typeof iss === "string" && typeof aud === "string" && typeof sub === "string" ? { iss, aud, sub } : null;
}

function accountUser(user: ServerUserLike): ChatGPTAccountUser {
  return { id: user.id, primaryEmail: user.primaryEmail, primaryEmailVerified: user.primaryEmailVerified, chatgpt: linkOf(user.serverMetadata) };
}

/** Accounts kept in Hexclave: the link lives in server metadata, sessions go into this browser's cookies. */
function hexclaveAccounts(): ChatGPTAccounts {
  const app = getStackServerApp();
  const userById = async (id: string) => (await app.getUser(id)) as unknown as ServerUserLike | null;
  return {
    async currentUser() {
      const user = (await app.getUser({ or: "return-null" })) as unknown as ServerUserLike | null;
      return user && !user.isAnonymous ? accountUser(user) : null;
    },
    async findByEmail(email) {
      const wanted = canonicalizeEmailForMatching(email);
      const users = (await app.listUsers({ query: email, limit: 20, includeRestricted: true })) as unknown as ServerUserLike[];
      const matches = users.filter((user) => user.primaryEmail && canonicalizeEmailForMatching(user.primaryEmail) === wanted);
      // A linked account wins over an unlinked duplicate with the same address.
      const match = matches.find((user) => linkOf(user.serverMetadata)) ?? matches[0];
      return match ? accountUser(match) : null;
    },
    async create({ email, name, link }) {
      try {
        const user = await app.createUser({
          primaryEmail: email,
          primaryEmailVerified: true,
          primaryEmailAuthEnabled: true,
          ...(name ? { displayName: name } : {}),
          serverMetadata: { [METADATA_KEY]: link },
        });
        return { id: user.id };
      } catch (caught) {
        if (
          KnownErrors.ContactChannelAlreadyUsedForAuthBySomeoneElse.isInstance(caught) ||
          KnownErrors.UserWithEmailAlreadyExists.isInstance(caught)
        ) {
          return "email-taken";
        }
        throw caught;
      }
    },
    async link(userId, link) {
      const user = await userById(userId);
      if (!user) throw new Error("user gone");
      const metadata = typeof user.serverMetadata === "object" && user.serverMetadata !== null ? user.serverMetadata : {};
      await user.update({ serverMetadata: { ...metadata, [METADATA_KEY]: link } });
    },
    async signIn(userId) {
      const user = await userById(userId);
      if (!user) throw new Error("user gone");
      const session = await user.createSession({ expiresInMillis: SESSION_EXPIRES_IN_MS });
      const tokens = await session.getTokens();
      if (!tokens.accessToken || !tokens.refreshToken) throw new Error("session has no tokens");
      // The server app's token store is this request's cookies (tokenStore "nextjs-cookie"),
      // so this writes the same session cookies a Google or GitHub sign-in leaves.
      const signInWithTokens = (app as unknown as { _signInToAccountWithTokens?: (tokens: { accessToken: string; refreshToken: string }) => Promise<void> })._signInToAccountWithTokens;
      if (typeof signInWithTokens !== "function") throw new Error("Hexclave SDK has no token sign-in");
      await signInWithTokens.call(app, { accessToken: tokens.accessToken, refreshToken: tokens.refreshToken });
    },
  };
}

function setCookie(response: NextResponse, request: NextRequest, name: string, value: string, maxAgeMs: number) {
  response.cookies.set(name, value, {
    httpOnly: true,
    secure: request.nextUrl.protocol === "https:",
    sameSite: "lax",
    path: CHATGPT_COOKIE_PATH,
    maxAge: Math.floor(maxAgeMs / 1000),
  });
}

function clearCookie(response: NextResponse, request: NextRequest, name: string) {
  setCookie(response, request, name, "", 0);
}

function noStore(response: NextResponse): NextResponse {
  response.headers.set("Cache-Control", "no-store");
  return response;
}

const notFound = () => new NextResponse("Not found", { status: 404 });

/** GET /handler/chatgpt/start?return_to=…: leaves for OpenAI. */
export async function startRoute(request: NextRequest): Promise<Response> {
  const config = await settings();
  if (!config) return notFound();
  const origin = requestOrigin(request);
  const started = await startChatGPTSignIn(config, { origin, returnTo: request.nextUrl.searchParams.get("return_to") });
  const response = NextResponse.redirect(started.redirect);
  setCookie(response, request, CHATGPT_TRANSACTION_COOKIE, started.transactionCookie, CHATGPT_TRANSACTION_TTL_MS);
  return noStore(response);
}

/** GET /handler/chatgpt/callback: OpenAI's redirect back. */
export async function callbackRoute(request: NextRequest): Promise<Response> {
  const config = await settings();
  if (!config) return notFound();
  const origin = requestOrigin(request);
  const outcome = await finishChatGPTSignIn(config, hexclaveAccounts(), {
    origin,
    query: request.nextUrl.searchParams,
    transactionCookie: request.cookies.get(CHATGPT_TRANSACTION_COOKIE)?.value ?? null,
  });
  if (outcome.kind === "failed") console.warn("[chatgpt sign-in] failed:", outcome.reason);
  const target = outcome.kind === "signed-in" ? outcome.returnTo : outcome.redirect;
  const response = NextResponse.redirect(new URL(target, origin));
  clearCookie(response, request, CHATGPT_TRANSACTION_COOKIE);
  if (outcome.kind === "link-required") {
    setCookie(response, request, CHATGPT_PENDING_LINK_COOKIE, outcome.pendingLinkCookie, CHATGPT_PENDING_LINK_TTL_MS);
  }
  return noStore(response);
}

/** GET /handler/chatgpt/link?return_to=…: after the usual sign-in, attaches the pending ChatGPT identity. */
export async function linkRoute(request: NextRequest): Promise<Response> {
  const config = await settings();
  if (!config) return notFound();
  const origin = requestOrigin(request);
  const result = await finishChatGPTLink(config, hexclaveAccounts(), {
    origin,
    pendingLinkCookie: request.cookies.get(CHATGPT_PENDING_LINK_COOKIE)?.value ?? null,
    returnTo: request.nextUrl.searchParams.get("return_to"),
  });
  const response = NextResponse.redirect(new URL(result.returnTo, origin));
  clearCookie(response, request, CHATGPT_PENDING_LINK_COOKIE);
  return noStore(response);
}
