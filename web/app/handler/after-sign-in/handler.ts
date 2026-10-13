import { NextRequest, NextResponse } from "next/server";
import {
  DEFAULT_NATIVE_CALLBACK_SCHEME,
  isAllowedNativeReturnTo,
} from "../../lib/native-callback";
import {
  APP_PRICING_NATIVE_RETURN_QUERY_PARAMS,
  verifiedAppPricingNativeReturnTo,
} from "../../lib/billing";
import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";
import {
  clearNativeHandoffCookie,
  NATIVE_HANDOFF_COOKIE_NAME,
  NATIVE_HANDOFF_QUERY_PARAM,
} from "../native-handoff-cookie";
import { requestOrigin } from "../../lib/request-origin";
import { hasAuthRateLimitSignal } from "../../../services/vms/authErrors";

const ANONYMOUS_IF_EXISTS = "anonymous-if-exists[deprecated]" as const;

type AfterSignInMessages = {
  title: string;
  body: string;
  button: string;
  switchAccountButton: string;
  rateLimitedTitle: string;
  rateLimitedBody: string;
  retryButton: string;
};

type BillingRecoveryMessages = {
  message?: unknown;
};

type LocalizedAfterSignInMessages = {
  locale: Locale;
  messages: AfterSignInMessages;
  recoveryMessage: string;
};

type CookieStore = {
  get: (name: string) => { value: string } | undefined;
  getAll: () => { name: string; value: string }[];
};

type StackAuthSessionLike = {
  getTokens: () => Promise<{
    refreshToken?: string | null;
    accessToken?: string | null;
  }>;
};

type StackAuthUserLike = {
  id?: string;
  primaryEmail?: string | null;
  primaryEmailVerified?: boolean;
  isAnonymous?: boolean;
  createSession: (options: { expiresInMillis: number }) => Promise<StackAuthSessionLike>;
};

type StackServerAppLike = {
  getUser: (options: {
    or: "return-null" | typeof ANONYMOUS_IF_EXISTS;
  }) => Promise<StackAuthUserLike | null>;
} | null;

type AfterSignInHandlerDependencies = {
  projectId: string | undefined;
  stackServerApp: StackServerAppLike;
  getCookieStore: () => Promise<CookieStore>;
  /** Promote an anonymous account only after Stack reports a verified email. */
  promoteVerifiedAnonymousUser?: (userId: string, email: string) => Promise<void>;
  /** Resolve paid claims after Stack has verified the mailbox. */
  claimVerifiedBilling?: (userId: string, email: string) => Promise<void>;
  /** Apply operator Pro grants addressed to the verified mailbox. */
  applyAdminGrants?: (userId: string, email: string) => Promise<void>;
};

function findStackCookie(
  cookieStore: { getAll: () => { name: string; value: string }[] },
  baseName: string
): string | undefined {
  const all = cookieStore.getAll();
  for (const prefix of ["__Host-", "__Secure-", ""]) {
    const withBranch = all.find(
      (c) => c.name.startsWith(`${prefix}${baseName}--`) && c.value
    );
    if (withBranch) return withBranch.value;
    const exact = all.find(
      (c) => c.name === `${prefix}${baseName}` && c.value
    );
    if (exact) return exact.value;
  }
  return undefined;
}

function decodeCookieValue(value: string | undefined): string | undefined {
  if (!value) return undefined;
  if (!value.includes("%")) return value;
  try {
    return decodeURIComponent(value);
  } catch {
    return undefined;
  }
}

function decodeAccessCookie(value: string | undefined): { refreshToken?: string; accessToken?: string } {
  const decoded = decodeCookieValue(value);
  if (!decoded) return {};
  if (!decoded.startsWith("[")) return { accessToken: decoded };
  try {
    const arr = JSON.parse(decoded) as unknown[];
    if (Array.isArray(arr) && arr.length >= 2) {
      return { refreshToken: arr[0] as string, accessToken: arr[1] as string };
    }
  } catch {}
  return {};
}

function decodeRefreshCookie(value: string | undefined): string | undefined {
  const decoded = decodeCookieValue(value);
  if (!decoded) return undefined;
  if (!decoded.startsWith("{")) return decoded;
  try {
    const obj = JSON.parse(decoded) as Record<string, unknown>;
    if (typeof obj.refresh_token === "string") return obj.refresh_token;
  } catch {}
  return undefined;
}

function buildNativeHref(
  baseHref: string | null,
  refreshToken: string | undefined,
  accessCookie: string | undefined
): string | null {
  if (!refreshToken || !accessCookie) return baseHref;
  const href = baseHref ?? `${DEFAULT_NATIVE_CALLBACK_SCHEME}://auth-callback`;
  try {
    const url = new URL(href);
    url.searchParams.set("stack_refresh", refreshToken);
    url.searchParams.set("stack_access", accessCookie);
    return url.toString();
  } catch {
    return `${DEFAULT_NATIVE_CALLBACK_SCHEME}://auth-callback?stack_refresh=${encodeURIComponent(refreshToken)}&stack_access=${encodeURIComponent(accessCookie)}`;
  }
}

function hasAuthState(href: string): boolean {
  try {
    return new URL(href).searchParams.has("cmux_auth_state");
  } catch {
    return false;
  }
}

function verifiedNativeHandoff(
  request: NextRequest,
  cookieStore: { get: (name: string) => { value: string } | undefined },
  nativeReturnTo: string
): boolean {
  if (!hasAuthState(nativeReturnTo)) return false;
  const handoffNonce = request.nextUrl.searchParams.get(NATIVE_HANDOFF_QUERY_PARAM);
  if (!handoffNonce) return false;
  return cookieStore.get(NATIVE_HANDOFF_COOKIE_NAME)?.value === handoffNonce;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function preferredLocale(request: NextRequest): Locale {
  const accepted = request.headers.get("accept-language") ?? "";
  const requested = accepted
    .split(",")
    .map((part) => part.split(";")[0]?.trim())
    .filter(Boolean);
  for (const language of requested) {
    const exact = locales.find((locale) => locale.toLowerCase() === language.toLowerCase());
    if (exact) return exact;
    const base = language.split("-")[0]?.toLowerCase();
    const baseMatch = locales.find((locale) => locale.toLowerCase().split("-")[0] === base);
    if (baseMatch) return baseMatch;
  }
  return routing.defaultLocale;
}

async function afterSignInMessages(request: NextRequest): Promise<LocalizedAfterSignInMessages> {
  const locale = preferredLocale(request);
  const messages = (await import(`../../../messages/${locale}.json`)).default as {
    afterSignIn?: AfterSignInMessages;
    billingRecovery?: BillingRecoveryMessages;
  };
  if (!messages.afterSignIn) {
    throw new Error(`Missing afterSignIn messages for locale ${locale}`);
  }
  return {
    locale,
    messages: messages.afterSignIn,
    recoveryMessage:
      typeof messages.billingRecovery?.message === "string"
        ? messages.billingRecovery.message
        : messages.afterSignIn.body,
  };
}

function nativeReturnResponse(
  href: string,
  localized: LocalizedAfterSignInMessages,
  switchAccountHref: string | null
): NextResponse {
  const { locale, messages } = localized;
  const escapedHref = escapeHtml(href);
  const switchAccountAction = switchAccountHref
    ? `      <a class="secondary" href="${escapeHtml(switchAccountHref)}">${escapeHtml(messages.switchAccountButton)}</a>\n`
    : "";
  const escapedTitle = escapeHtml(messages.title);
  const escapedBody = escapeHtml(messages.body);
  const escapedButton = escapeHtml(messages.button);
  const response = new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(locale)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapedTitle}</title>
  <style>
    body {
      align-items: center;
      background: #fff;
      color: #111;
      display: flex;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
      justify-content: center;
      margin: 0;
      min-height: 100vh;
      padding: 24px;
    }
    main {
      max-width: 440px;
      text-align: center;
    }
    h1 {
      font-size: 24px;
      font-weight: 600;
      margin: 0 0 12px;
    }
    p {
      color: #555;
      line-height: 1.5;
      margin: 0 0 24px;
    }
    .actions {
      align-items: center;
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    a {
      border-radius: 8px;
      display: inline-block;
      font-size: 14px;
      font-weight: 500;
      padding: 10px 18px;
      text-decoration: none;
    }
    a.primary {
      background: #111;
      color: #fff;
    }
    a.secondary {
      color: #555;
    }
  </style>
</head>
<body>
  <main>
    <h1>${escapedTitle}</h1>
    <p>${escapedBody}</p>
    <div class="actions">
      <a class="primary" href="${escapedHref}">${escapedButton}</a>
${switchAccountAction}    </div>
  </main>
</body>
</html>`,
    {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    }
  );
  return response;
}

function nativeRedirectResponse(request: NextRequest, href: string): NextResponse {
  const response = NextResponse.redirect(href);
  response.headers.set("Cache-Control", "no-store");
  clearNativeHandoffCookie(response, request);
  return response;
}

function anonymousPromotionFailureResponse(
  request: NextRequest,
  localized: LocalizedAfterSignInMessages,
  retryHref: string | null,
): NextResponse {
  const href = retryHref ?? new URL("/handler/sign-in", requestOrigin(request)).toString();
  const response = new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(localized.locale)}">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(localized.messages.title)}</title></head>
<body>
  <main>
    <h1>${escapeHtml(localized.messages.title)}</h1>
    <p>${escapeHtml(localized.recoveryMessage)}</p>
    <a href="${escapeHtml(href)}">${escapeHtml(localized.messages.switchAccountButton)}</a>
  </main>
</body>
</html>`,
    {
      status: 503,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Retry-After": "0",
      },
    },
  );
  return response;
}

function currentAfterSignInPath(request: NextRequest): string {
  const afterSignIn = new URL(request.nextUrl.pathname, requestOrigin(request));
  const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
  if (nativeReturnTo) afterSignIn.searchParams.set("native_app_return_to", nativeReturnTo);
  for (const name of APP_PRICING_NATIVE_RETURN_QUERY_PARAMS) {
    const value = request.nextUrl.searchParams.get(name);
    if (value) afterSignIn.searchParams.set(name, value);
  }
  const webReturnTo = request.nextUrl.searchParams.get("web_return_to");
  if (webReturnTo) afterSignIn.searchParams.set("web_return_to", webReturnTo);
  return `${afterSignIn.pathname}${afterSignIn.search}`;
}

function switchAccountHref(request: NextRequest): string | null {
  if (!request.nextUrl.searchParams.has("native_app_return_to")) return null;
  const nativeSignIn = new URL("/handler/native-sign-in", requestOrigin(request));
  nativeSignIn.searchParams.set("after_auth_return_to", currentAfterSignInPath(request));

  const signOut = new URL("/handler/sign-out-and-sign-in", requestOrigin(request));
  signOut.searchParams.set("after_auth_return_to", `${nativeSignIn.pathname}${nativeSignIn.search}`);
  return `${signOut.pathname}${signOut.search}`;
}

type FreshSession =
  | { readonly kind: "tokens"; readonly refreshToken?: string; readonly accessToken?: string }
  | { readonly kind: "response"; readonly response: NextResponse };

/**
 * Read the signed-in (or anonymous) user, finish account promotion, billing
 * claims and admin grants, and mint a fresh 30-day session. A Stack throttle
 * anywhere in this answers a retry page: continuing with the old cookie
 * tokens would skip the promotion and the claim this callback exists for.
 * Any other failure keeps the cookie tokens, as before.
 */
async function mintFreshSession(
  authApp: NonNullable<StackServerAppLike>,
  dependencies: AfterSignInHandlerDependencies,
  request: NextRequest,
  localizedMessages: LocalizedAfterSignInMessages,
): Promise<FreshSession> {
  try {
    const user =
      (await authApp.getUser({ or: "return-null" })) ??
      (await authApp.getUser({ or: ANONYMOUS_IF_EXISTS }));
    if (!user) return { kind: "tokens" };
    const promoted = await promoteVerifiedAnonymous(user, dependencies);
    if (promoted === "failed") {
      return {
        kind: "response",
        response: anonymousPromotionFailureResponse(request, localizedMessages, switchAccountHref(request)),
      };
    }
    if (user.id && user.primaryEmail && (promoted === "promoted" || isVerifiedAccount(user))) {
      await runVerifiedAccountSideEffects(user.id, user.primaryEmail, dependencies);
    }
    const session = await user.createSession({ expiresInMillis: 30 * 24 * 60 * 60 * 1000 });
    const tokens = await session.getTokens();
    return { kind: "tokens", refreshToken: tokens.refreshToken || undefined, accessToken: tokens.accessToken || undefined };
  } catch (error) {
    if (hasAuthRateLimitSignal(error)) {
      console.error("auth.after_sign_in.stack_throttled", { failure: "rate_limited" });
      return { kind: "response", response: stackThrottledResponse(request, localizedMessages) };
    }
    console.error("[After Sign In] Failed to create fresh session", error);
    return { kind: "tokens" };
  }
}

function isVerifiedAccount(user: StackAuthUserLike): boolean {
  return user.isAnonymous !== true && user.primaryEmailVerified === true;
}

async function promoteVerifiedAnonymous(
  user: StackAuthUserLike,
  dependencies: AfterSignInHandlerDependencies,
): Promise<"promoted" | "not_needed" | "failed"> {
  if (
    user.isAnonymous !== true ||
    user.primaryEmailVerified !== true ||
    !user.primaryEmail ||
    !user.id ||
    !dependencies.promoteVerifiedAnonymousUser
  ) {
    return "not_needed";
  }
  try {
    // The callback is reached after Stack has accepted the one-time
    // email link. Only then may the anonymous restriction be removed.
    await dependencies.promoteVerifiedAnonymousUser(user.id, user.primaryEmail);
    return "promoted";
  } catch (error) {
    // A throttle gets the retry page; the link is still valid for a retry.
    if (hasAuthRateLimitSignal(error)) throw error;
    console.error("auth.after_sign_in.anonymous_promotion_failed", {
      failure: "provider_unavailable",
    });
    // Stack has consumed the one-time link, so do not mint a session that
    // still carries the anonymous restriction. Return a retryable recovery
    // state instead.
    return "failed";
  }
}

async function runVerifiedAccountSideEffects(
  userId: string,
  email: string,
  dependencies: AfterSignInHandlerDependencies,
): Promise<void> {
  if (dependencies.claimVerifiedBilling) {
    try {
      // The callback re-reads the user after any anonymous promotion, so
      // claim resolution sees Stack's committed verification state.
      await dependencies.claimVerifiedBilling(userId, email);
    } catch {
      // Authentication must remain available if billing storage or
      // Stripe is temporarily unavailable. Billing reads and the next
      // sign-in retry the idempotent claim transfer.
      console.error("billing.after_sign_in.claim_failed", {
        failure: "provider_unavailable",
      });
    }
  }
  if (dependencies.applyAdminGrants) {
    try {
      await dependencies.applyAdminGrants(userId, email);
    } catch {
      // Sign-in must not depend on the grants table; the next sign-in
      // retries because unapplied rows stay open.
      console.error("admin.after_sign_in.grant_apply_failed", {
        failure: "provider_unavailable",
      });
    }
  }
}

/** Seconds a throttled sign-in callback asks the browser to wait. */
const STACK_THROTTLE_RETRY_AFTER_SECONDS = 30;

/**
 * Stack throttled the callback. The page links back to this exact callback
 * URL, so a retry resumes the same flow with the same cookies and handoff.
 */
function stackThrottledResponse(
  request: NextRequest,
  localized: LocalizedAfterSignInMessages,
): NextResponse {
  const retryHref = `${request.nextUrl.pathname}${request.nextUrl.search}`;
  const messages = localized.messages;
  return new NextResponse(
    `<!doctype html>
<html lang="${escapeHtml(localized.locale)}">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(messages.rateLimitedTitle)}</title></head>
<body>
  <main>
    <h1>${escapeHtml(messages.rateLimitedTitle)}</h1>
    <p>${escapeHtml(messages.rateLimitedBody)}</p>
    <a href="${escapeHtml(retryHref)}">${escapeHtml(messages.retryButton)}</a>
  </main>
</body>
</html>`,
    {
      status: 503,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Retry-After": String(STACK_THROTTLE_RETRY_AFTER_SECONDS),
      },
    },
  );
}

/** Hand fresh tokens back to an allowed native return target, or go home. */
function nativeReturnFlow(
  request: NextRequest,
  stackCookies: CookieStore,
  nativeReturnTo: string,
  refreshToken: string,
  accessCookie: string,
  localizedMessages: LocalizedAfterSignInMessages,
): NextResponse {
  const trustedPurchaseReturnTo = verifiedAppPricingNativeReturnTo(request.nextUrl);
  if (
    trustedPurchaseReturnTo === nativeReturnTo ||
    isAllowedNativeReturnTo(nativeReturnTo, request)
  ) {
    const href = buildNativeHref(nativeReturnTo, refreshToken, accessCookie);
    if (href) {
      if (verifiedNativeHandoff(request, stackCookies, nativeReturnTo)) {
        return nativeRedirectResponse(request, href);
      }
      return nativeReturnResponse(href, localizedMessages, switchAccountHref(request));
    }
  }
  return NextResponse.redirect(new URL("/", requestOrigin(request)));
}

export function makeAfterSignInHandler(dependencies: AfterSignInHandlerDependencies) {
  return async function GET(request: NextRequest) {
    const projectId = dependencies.projectId;
    const authApp = dependencies.stackServerApp;
    if (!authApp || !projectId) return NextResponse.redirect(new URL("/", requestOrigin(request)));
    const localizedMessages = await afterSignInMessages(request);

    const stackCookies = await dependencies.getCookieStore();
    const refreshBaseName = `stack-refresh-${projectId}`;
    const rawRefreshCookie = findStackCookie(stackCookies, refreshBaseName);
    const rawAccessCookie = findStackCookie(stackCookies, "stack-access");
    const parsedAccess = decodeAccessCookie(rawAccessCookie);
    const parsedRefresh = decodeRefreshCookie(rawRefreshCookie);

    let refreshToken = parsedAccess.refreshToken ?? parsedRefresh;
    let accessToken = parsedAccess.accessToken;
    let accessCookie = decodeCookieValue(rawAccessCookie);

    const fresh = await mintFreshSession(authApp, dependencies, request, localizedMessages);
    if (fresh.kind === "response") return fresh.response;
    refreshToken = fresh.refreshToken ?? refreshToken;
    accessToken = fresh.accessToken ?? accessToken;

    if (refreshToken && accessToken) {
      accessCookie = JSON.stringify([refreshToken, accessToken]);
    }

    const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
    if (refreshToken && accessCookie && nativeReturnTo !== null) {
      return nativeReturnFlow(request, stackCookies, nativeReturnTo, refreshToken, accessCookie, localizedMessages);
    }

    const afterAuth = request.nextUrl.searchParams.get("after_auth_return_to");
    if (afterAuth && afterAuth.startsWith("/") && !afterAuth.startsWith("//")) {
      return NextResponse.redirect(new URL(afterAuth, requestOrigin(request)));
    }

    if (refreshToken && accessCookie) {
      const fallback = buildNativeHref(null, refreshToken, accessCookie);
      if (fallback) return nativeReturnResponse(fallback, localizedMessages, switchAccountHref(request));
    }

    return NextResponse.redirect(new URL("/", requestOrigin(request)));
  };
}
