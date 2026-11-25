import { randomBytes, timingSafeEqual, createHash } from "crypto";
import type { NextRequest, NextResponse } from "next/server";

/**
 * The after-sign-in confirmation nonce. The confirmation page sets it and
 * its button echoes it, so a hand-off to an app proceeds only from that
 * page's own link.
 *
 * The cookie is `__Host-` (Secure, `Path=/`, no `Domain`), so a subdomain
 * cannot plant one. Its value binds the nonce to its purpose and to the one
 * path that may read it, so the wider cookie path does not widen its use.
 *
 * Local development over plain `http://localhost` cannot keep a Secure
 * cookie, so there (and only outside production) the cookie has another name
 * and no Secure flag. A deployed origin is always HTTPS and always `__Host-`.
 */
export const NATIVE_CONFIRM_COOKIE_NAME = "__Host-cmux-native-auth-confirm";
export const NATIVE_CONFIRM_DEV_COOKIE_NAME = "cmux-native-auth-confirm-dev";
export const NATIVE_CONFIRM_QUERY_PARAM = "cmux_auth_confirm";

const CONFIRM_PURPOSE = "native-confirm";
const CONFIRM_PATH = "/handler/after-sign-in";
const CONFIRM_TTL_SECONDS = 10 * 60;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1"]);

type ConfirmCookie = { name: string; secure: boolean };

/** The cookie for `request`'s origin: `__Host-` everywhere but plain-HTTP loopback in development. */
function confirmCookieFor(request: NextRequest): ConfirmCookie {
  const url = request.nextUrl;
  const insecureLocalDevelopment =
    process.env.NODE_ENV !== "production" && url.protocol === "http:" && LOOPBACK_HOSTS.has(url.hostname);
  return insecureLocalDevelopment
    ? { name: NATIVE_CONFIRM_DEV_COOKIE_NAME, secure: false }
    : { name: NATIVE_CONFIRM_COOKIE_NAME, secure: true };
}

function boundValue(nonce: string): string {
  return `v1.${CONFIRM_PURPOSE}.${CONFIRM_PATH}.${nonce}`;
}

function digest(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

function writeConfirmCookie(response: NextResponse, request: NextRequest, value: string, maxAge: number): void {
  const cookie = confirmCookieFor(request);
  response.cookies.set(cookie.name, value, {
    httpOnly: true,
    maxAge,
    path: "/",
    sameSite: "lax",
    secure: cookie.secure,
  });
}

/** A fresh 256-bit confirmation nonce for the page's link. */
export function makeNativeConfirmNonce(): string {
  return randomBytes(32).toString("base64url");
}

/** Set `nonce`, bound to its purpose and path, as the confirmation cookie. */
export function issueNativeConfirmCookie(response: NextResponse, request: NextRequest, nonce: string): void {
  writeConfirmCookie(response, request, boundValue(nonce), CONFIRM_TTL_SECONDS);
}

export function clearNativeConfirmCookie(response: NextResponse, request: NextRequest): void {
  writeConfirmCookie(response, request, "", 0);
}

/**
 * Whether this request is the confirmation page's own link: the query nonce
 * matches the cookie, the cookie was bound to this purpose and path, and the
 * request is on that path.
 */
export function verifiedNativeConfirmation(
  request: NextRequest,
  cookieStore: { get: (name: string) => { value: string } | undefined },
): boolean {
  if (request.nextUrl.pathname !== CONFIRM_PATH) return false;
  const nonce = request.nextUrl.searchParams.get(NATIVE_CONFIRM_QUERY_PARAM);
  if (!nonce || !NONCE_PATTERN.test(nonce)) return false;
  const cookie = cookieStore.get(confirmCookieFor(request).name)?.value;
  if (!cookie) return false;
  return timingSafeEqual(digest(cookie), digest(boundValue(nonce)));
}
