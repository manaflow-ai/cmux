import { randomUUID } from "crypto";
import { NextRequest, NextResponse } from "next/server";
import { isAllowedNativeReturnTo } from "../../lib/native-callback";
import {
  isValidCodeChallenge,
  issueNativeSignInCode,
  PKCE_METHOD_S256,
  type NativeSignInCodeStore,
} from "../../lib/native-sign-in-codes";
import {
  APP_PRICING_NATIVE_RETURN_QUERY_PARAMS,
  verifiedAppPricingNativeReturnTo,
} from "../../lib/billing";
import type { Locale } from "../../../i18n/routing";
import { locales, routing } from "../../../i18n/routing";
import {
  clearNativeConfirmCookie,
  clearNativeHandoffCookie,
  issueNativeConfirmCookie,
  NATIVE_CONFIRM_COOKIE_NAME,
  NATIVE_CONFIRM_QUERY_PARAM,
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
  /** Where one-time native sign-in codes are kept (PKCE hand-off). */
  nativeSignInCodeStore?: NativeSignInCodeStore;
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

/** Query names a callback URL must only carry when this handler sets them. */
const CALLBACK_CREDENTIAL_PARAMS = ["stack_refresh", "stack_access", "code"] as const;

/**
 * The validated native return target with `credentials` set, and any
 * credential-looking parameter the request supplied removed.
 */
function nativeCallbackHref(nativeReturnTo: string, credentials: Record<string, string>): string | null {
  try {
    const url = new URL(nativeReturnTo);
    for (const name of CALLBACK_CREDENTIAL_PARAMS) url.searchParams.delete(name);
    for (const [name, value] of Object.entries(credentials)) url.searchParams.set(name, value);
    return url.toString();
  } catch {
    return null;
  }
}

function nativeReturnScheme(nativeReturnTo: string): string | null {
  try {
    return new URL(nativeReturnTo).protocol.replace(/:$/, "").toLowerCase();
  } catch {
    return null;
  }
}

/** The request's PKCE challenge: absent (`null`), valid, or `"invalid"`. */
function requestedCodeChallenge(request: NextRequest): string | null | "invalid" {
  const challenge = request.nextUrl.searchParams.get("code_challenge");
  if (challenge === null) return null;
  const method = request.nextUrl.searchParams.get("code_challenge_method");
  return isValidCodeChallenge(challenge) && method === PKCE_METHOD_S256 ? challenge : "invalid";
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

/** The person clicked this page's own confirmation link. */
function verifiedNativeConfirmation(
  request: NextRequest,
  cookieStore: { get: (name: string) => { value: string } | undefined },
): boolean {
  const nonce = request.nextUrl.searchParams.get(NATIVE_CONFIRM_QUERY_PARAM);
  if (!nonce) return false;
  return cookieStore.get(NATIVE_CONFIRM_COOKIE_NAME)?.value === nonce;
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
  clearNativeConfirmCookie(response, request);
  return response;
}

/**
 * The page that asks for a click before the hand-off. Its button returns to
 * this callback with a nonce that only this response's cookie matches; no
 * session or code exists until that click.
 */
function nativeConfirmationResponse(
  request: NextRequest,
  localized: LocalizedAfterSignInMessages,
): NextResponse {
  const nonce = randomUUID();
  const confirm = new URL(currentAfterSignInPath(request), requestOrigin(request));
  confirm.searchParams.set(NATIVE_CONFIRM_QUERY_PARAM, nonce);
  const response = nativeReturnResponse(
    `${confirm.pathname}${confirm.search}`,
    localized,
    switchAccountHref(request),
  );
  issueNativeConfirmCookie(response, request, nonce);
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
  for (const name of [...APP_PRICING_NATIVE_RETURN_QUERY_PARAMS, "code_challenge", "code_challenge_method"]) {
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

/** Lifetime of a session minted for the native app. */
const NATIVE_SESSION_EXPIRES_IN_MILLIS = 30 * 24 * 60 * 60 * 1000;

type ResolvedUser =
  | { readonly kind: "user"; readonly user: StackAuthUserLike | null; readonly lookupFailed?: boolean }
  | { readonly kind: "response"; readonly response: NextResponse };

/**
 * Read the signed-in (or anonymous) user and finish account promotion,
 * billing claims and admin grants. No session is minted here. A Stack
 * throttle answers a retry page: continuing would skip the promotion and the
 * claim this callback exists for. Any other failure reads as no user.
 */
async function resolveSignedInUser(
  authApp: NonNullable<StackServerAppLike>,
  dependencies: AfterSignInHandlerDependencies,
  request: NextRequest,
  localizedMessages: LocalizedAfterSignInMessages,
): Promise<ResolvedUser> {
  try {
    const user =
      (await authApp.getUser({ or: "return-null" })) ??
      (await authApp.getUser({ or: ANONYMOUS_IF_EXISTS }));
    if (!user) return { kind: "user", user: null };
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
    return { kind: "user", user };
  } catch (error) {
    if (hasAuthRateLimitSignal(error)) {
      console.error("auth.after_sign_in.stack_throttled", { failure: "rate_limited" });
      return { kind: "response", response: stackThrottledResponse(request, localizedMessages) };
    }
    console.error("[After Sign In] Failed to read the signed-in user", error);
    return { kind: "user", user: null, lookupFailed: true };
  }
}

type LegacySession =
  | { readonly kind: "tokens"; readonly refreshToken?: string; readonly accessCookie?: string }
  | { readonly kind: "response"; readonly response: NextResponse };

/**
 * Legacy hand-off only (apps that send no PKCE challenge): mint a fresh
 * session, keeping the cookie tokens when minting fails, as before.
 */
async function mintLegacySession(
  user: StackAuthUserLike | null,
  stackCookies: CookieStore,
  projectId: string,
  request: NextRequest,
  localizedMessages: LocalizedAfterSignInMessages,
): Promise<LegacySession> {
  const rawAccessCookie = findStackCookie(stackCookies, "stack-access");
  const parsedAccess = decodeAccessCookie(rawAccessCookie);
  let refreshToken = parsedAccess.refreshToken ??
    decodeRefreshCookie(findStackCookie(stackCookies, `stack-refresh-${projectId}`));
  let accessToken = parsedAccess.accessToken;
  let accessCookie = decodeCookieValue(rawAccessCookie);
  try {
    if (user) {
      const tokens = await (await user.createSession({ expiresInMillis: NATIVE_SESSION_EXPIRES_IN_MILLIS })).getTokens();
      refreshToken = tokens.refreshToken || refreshToken;
      accessToken = tokens.accessToken || accessToken;
    }
  } catch (error) {
    if (hasAuthRateLimitSignal(error)) {
      console.error("auth.after_sign_in.stack_throttled", { failure: "rate_limited" });
      return { kind: "response", response: stackThrottledResponse(request, localizedMessages) };
    }
    console.error("[After Sign In] Failed to create fresh session", error);
  }
  if (refreshToken && accessToken) accessCookie = JSON.stringify([refreshToken, accessToken]);
  return { kind: "tokens", refreshToken, accessCookie };
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

type NativeReturnContext = {
  readonly request: NextRequest;
  readonly stackCookies: CookieStore;
  readonly nativeReturnTo: string;
  readonly user: StackAuthUserLike | null;
  /** Reading the user failed for a reason other than a throttle. */
  readonly userLookupFailed: boolean;
  readonly projectId: string;
  readonly dependencies: AfterSignInHandlerDependencies;
  readonly localizedMessages: LocalizedAfterSignInMessages;
};

function homeRedirect(request: NextRequest): NextResponse {
  return NextResponse.redirect(new URL("/", requestOrigin(request)));
}

/**
 * PKCE hand-off: store a one-time code bound to the app's challenge and
 * scheme and send the app only that code with its state. The session is
 * minted when the app redeems the code (`/api/native/token`).
 */
async function nativeCodeHandoff(context: NativeReturnContext, codeChallenge: string): Promise<NextResponse> {
  const { request, nativeReturnTo, user, dependencies, localizedMessages } = context;
  const scheme = nativeReturnScheme(nativeReturnTo);
  // A failed lookup is retried on this same callback rather than stranding
  // the app's attempt on the home page.
  if (context.userLookupFailed) return stackThrottledResponse(request, localizedMessages);
  if (!user?.id || !scheme) {
    console.error("auth.after_sign_in.native_code_unavailable", { failure: "no_user" });
    return homeRedirect(request);
  }
  const store = dependencies.nativeSignInCodeStore;
  let code: string;
  try {
    if (!store) throw new Error("native sign-in code store is not configured");
    code = await issueNativeSignInCode(store, { userId: user.id, codeChallenge, scheme });
  } catch (error) {
    console.error("auth.after_sign_in.native_code_unavailable", { failure: "store_unavailable" }, error);
    return stackThrottledResponse(request, localizedMessages);
  }
  const href = nativeCallbackHref(nativeReturnTo, { code });
  return href ? nativeRedirectResponse(request, href) : homeRedirect(request);
}

/**
 * Legacy hand-off for apps that send no challenge: tokens in the callback
 * URL, only after the person clicked this page's confirmation link.
 */
async function nativeLegacyTokenHandoff(context: NativeReturnContext): Promise<NextResponse> {
  const { request, stackCookies, nativeReturnTo, user, projectId, localizedMessages } = context;
  const minted = await mintLegacySession(user, stackCookies, projectId, request, localizedMessages);
  if (minted.kind === "response") return minted.response;
  if (!minted.refreshToken || !minted.accessCookie) return homeRedirect(request);
  const href = nativeCallbackHref(nativeReturnTo, {
    stack_refresh: minted.refreshToken,
    stack_access: minted.accessCookie,
  });
  return href ? nativeRedirectResponse(request, href) : homeRedirect(request);
}

/** Hand off to an allowed native return target, or go home. */
async function nativeReturnFlow(context: NativeReturnContext): Promise<NextResponse> {
  const { request, stackCookies, nativeReturnTo, localizedMessages } = context;
  const trustedPurchaseReturnTo = verifiedAppPricingNativeReturnTo(request.nextUrl);
  if (trustedPurchaseReturnTo !== nativeReturnTo && !isAllowedNativeReturnTo(nativeReturnTo, request)) {
    return homeRedirect(request);
  }
  const codeChallenge = requestedCodeChallenge(request);
  if (codeChallenge === "invalid") return homeRedirect(request);
  const confirmed = verifiedNativeConfirmation(request, stackCookies);
  if (codeChallenge) {
    if (confirmed || verifiedNativeHandoff(request, stackCookies, nativeReturnTo)) {
      return nativeCodeHandoff(context, codeChallenge);
    }
    return nativeConfirmationResponse(request, localizedMessages);
  }
  // Builds without PKCE keep signing in during the transition, but their
  // token URL is never sent without the person's click on this page.
  console.warn("auth.after_sign_in.legacy_native_handoff", { confirmed });
  if (!confirmed) return nativeConfirmationResponse(request, localizedMessages);
  return nativeLegacyTokenHandoff(context);
}

export function makeAfterSignInHandler(dependencies: AfterSignInHandlerDependencies) {
  return async function GET(request: NextRequest) {
    const projectId = dependencies.projectId;
    const authApp = dependencies.stackServerApp;
    if (!authApp || !projectId) return homeRedirect(request);
    const localizedMessages = await afterSignInMessages(request);
    const stackCookies = await dependencies.getCookieStore();

    const resolved = await resolveSignedInUser(authApp, dependencies, request, localizedMessages);
    if (resolved.kind === "response") return resolved.response;

    const nativeReturnTo = request.nextUrl.searchParams.get("native_app_return_to");
    if (nativeReturnTo !== null) {
      return nativeReturnFlow({
        request,
        stackCookies,
        nativeReturnTo,
        user: resolved.user,
        userLookupFailed: resolved.lookupFailed === true,
        projectId,
        dependencies,
        localizedMessages,
      });
    }

    const afterAuth = request.nextUrl.searchParams.get("after_auth_return_to");
    if (afterAuth && afterAuth.startsWith("/") && !afterAuth.startsWith("//")) {
      return NextResponse.redirect(new URL(afterAuth, requestOrigin(request)));
    }
    return homeRedirect(request);
  };
}
