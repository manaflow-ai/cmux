import type { NextRequest } from "next/server";
import { isAllowedNativeScheme } from "../../../lib/native-callback";
import {
  redeemNativeSignInCode,
  type NativeSignInCodeStore,
} from "../../../lib/native-sign-in-codes";
import { hasAuthRateLimitSignal } from "../../../../services/vms/authErrors";

/** A redemption body is three short strings. */
const MAX_BODY_BYTES = 4 * 1024;

/** Lifetime of the session minted for the app (as the browser hand-off did). */
const NATIVE_SESSION_EXPIRES_IN_MILLIS = 30 * 24 * 60 * 60 * 1000;

type SessionUser = {
  createSession: (options: { expiresInMillis: number }) => Promise<{
    getTokens: () => Promise<{ refreshToken?: string | null; accessToken?: string | null }>;
  }>;
};

export type NativeTokenHandlerDependencies = {
  store: NativeSignInCodeStore | null;
  getUserById: ((userId: string) => Promise<SessionUser | null>) | null;
  now?: () => number;
};

function json(body: Record<string, string>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      Pragma: "no-cache",
    },
  });
}

/** Every refusal looks the same, so a caller learns nothing about why. */
function invalidGrant(): Response {
  return json({ error: "invalid_grant" }, 400);
}

async function readBody(request: NextRequest): Promise<Record<string, unknown> | null> {
  const contentType = request.headers.get("content-type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) return null;
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) return null;
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return null;
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

async function mintTokens(
  getUserById: (userId: string) => Promise<SessionUser | null>,
  userId: string,
): Promise<{ refreshToken: string; accessToken: string } | null> {
  const user = await getUserById(userId);
  if (!user) return null;
  const session = await user.createSession({ expiresInMillis: NATIVE_SESSION_EXPIRES_IN_MILLIS });
  const tokens = await session.getTokens();
  if (!tokens.refreshToken || !tokens.accessToken) return null;
  return { refreshToken: tokens.refreshToken, accessToken: tokens.accessToken };
}

/**
 * `POST /api/native/token`: the app redeems a one-time sign-in code with its
 * PKCE verifier. The code is consumed by this call whatever the outcome; on a
 * match the session is minted here and its tokens return in the body only.
 */
export function makeNativeTokenHandler(dependencies: NativeTokenHandlerDependencies) {
  return async function POST(request: NextRequest): Promise<Response> {
    const { store, getUserById } = dependencies;
    if (!store || !getUserById) return json({ error: "unavailable" }, 503);
    const body = await readBody(request);
    if (!body) return invalidGrant();
    const { code, code_verifier: codeVerifier, scheme } = body;
    if (typeof scheme !== "string" || !isAllowedNativeScheme(scheme.trim().toLowerCase(), request)) {
      return invalidGrant();
    }
    try {
      const redeemed = await redeemNativeSignInCode(store, { code, codeVerifier, scheme }, dependencies.now);
      if (!redeemed) return invalidGrant();
      const tokens = await mintTokens(getUserById, redeemed.userId);
      if (!tokens) return invalidGrant();
      return json({ refresh_token: tokens.refreshToken, access_token: tokens.accessToken }, 200);
    } catch (error) {
      const failure = hasAuthRateLimitSignal(error) ? "rate_limited" : "unavailable";
      console.error("auth.native_token.redeem_failed", { failure });
      return json({ error: "unavailable" }, 503);
    }
  };
}
