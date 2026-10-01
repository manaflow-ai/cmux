// Decides what the sign-in page shows before any form renders. Kept free of
// React and the SDK so every branch is unit tested.

export type SignInEntry = "form" | "choose-account" | "continue" | "onboarding";

/** Asks the page to confirm the account even when the browser is signed in. */
export const SELECT_ACCOUNT_PROMPT = "select_account";

/**
 * Every signed-in arrival confirms the account when true. Off: only an
 * explicit `prompt=select_account` (the app's Switch Account) shows the
 * chooser, and other signed-in arrivals continue as before.
 */
export const CHOOSE_ACCOUNT_ON_EVERY_SIGNED_IN_ARRIVAL = false;

/**
 * A signed-out browser that has signed in before lists those accounts first,
 * like Gmail, when true. Off: it always opens on the form.
 */
export const CHOOSE_ACCOUNT_WHEN_SIGNED_OUT = true;

export function signInEntry(input: {
  hasUser: boolean;
  isRestricted: boolean;
  prompt: string | null;
  returningFromOAuth: boolean;
  /** Sign-in (not sign-up) with remembered accounts to list. */
  hasRememberedAccounts?: boolean;
  chooseOnEverySignedInArrival?: boolean;
  chooseWhenSignedOut?: boolean;
}): SignInEntry {
  if (!input.hasUser) {
    const listRemembered = input.chooseWhenSignedOut ?? CHOOSE_ACCOUNT_WHEN_SIGNED_OUT;
    return listRemembered && input.hasRememberedAccounts && !input.returningFromOAuth ? "choose-account" : "form";
  }
  if (input.isRestricted) return "onboarding";
  // OAuth finishes by landing back here signed in, with the same query
  // (prompt included). That landing must continue, or every OAuth login
  // stalls on a chooser for the account it just signed in to.
  if (input.returningFromOAuth) return "continue";
  if (input.prompt === SELECT_ACCOUNT_PROMPT) return "choose-account";
  if (input.chooseOnEverySignedInArrival ?? CHOOSE_ACCOUNT_ON_EVERY_SIGNED_IN_ARRIVAL) return "choose-account";
  return "continue";
}

// MARK: OAuth return marker

/**
 * Set on this page's own URL just before leaving for an OAuth provider. The
 * provider's callback returns to that exact URL, so the landing can tell
 * "finishing the login started here" from "arrived already signed in".
 * It lives in the query, not in storage, so the server render and the
 * browser make the same decision. A hand-made link with it only skips the
 * account confirmation, which is the pre-chooser behaviour.
 */
export const CONTINUE_PARAM = "cmux_continue";

export function isReturningFromOAuth(params: { get(name: string): string | null }): boolean {
  return params.get(CONTINUE_PARAM) === "1";
}

/** The current URL with the OAuth return marker added. */
export function withContinueMarker(href: string): string {
  const url = new URL(href);
  url.searchParams.set(CONTINUE_PARAM, "1");
  return url.toString();
}

/** The current URL without the marker (an OAuth start that failed). */
export function withoutContinueMarker(href: string): string {
  const url = new URL(href);
  url.searchParams.delete(CONTINUE_PARAM);
  return url.toString();
}

// MARK: Links that keep the return target

/** `/handler/<page>` with only `after_auth_return_to` carried over. */
export function handlerHref(page: "sign-in" | "sign-up" | "forgot-password", returnTo: string | null): string {
  const url = new URL(`/handler/${page}`, "https://cmux.com");
  if (returnTo) url.searchParams.set("after_auth_return_to", returnTo);
  return `${url.pathname}${url.search}`;
}

/** Where a successful password sign-up waits for email verification. */
export function signUpPendingHref(current: URL): string {
  const url = new URL("/handler/auth-error", current);
  url.searchParams.set("code", "signup-pending");
  for (const name of ["after_auth_return_to", "web_return_to", "native_app_return_to"]) {
    const value = current.searchParams.get(name);
    if (value) url.searchParams.set(name, value);
  }
  return url.toString();
}

/** Initials for the account tile, from a display name or an email. */
export function accountInitials(displayName: string | null | undefined, email: string | null | undefined): string {
  const name = displayName?.trim();
  if (name) {
    const parts = name.split(/\s+/).filter(Boolean);
    const letters = parts.length > 1 ? parts[0][0] + parts[parts.length - 1][0] : parts[0].slice(0, 2);
    return letters.toUpperCase();
  }
  const local = email?.split("@")[0]?.trim();
  return local ? local.slice(0, 2).toUpperCase() : "?";
}

// MARK: Accounts this browser has used

/**
 * Accounts that signed in on this browser, newest first, for the chooser.
 * No tokens here: those live in the server-only saved sessions
 * (account-sessions.ts). Picking a saved account switches to it; one whose
 * session ended signs in again through its own method. Nothing is signed out
 * first.
 */
export type RememberedAccount = {
  id: string;
  email: string | null;
  displayName: string | null;
  profileImageUrl?: string | null;
  /** The OAuth provider this account signs in with, or null for email. */
  signInMethod?: string | null;
  /** Has a password: the form for it opens on email and password. */
  hasPassword?: boolean;
  lastSeenAt: number;
};

export const ACCOUNT_HISTORY_KEY = "cmux.signIn.accounts";
export const ACCOUNT_HISTORY_LIMIT = 5;

export function parseAccountHistory(raw: string | null): RememberedAccount[] {
  if (!raw) return [];
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(value)) return [];
  const accounts: RememberedAccount[] = [];
  for (const item of value) {
    if (typeof item !== "object" || item === null) continue;
    const { id, email, displayName, profileImageUrl, signInMethod, hasPassword, lastSeenAt } = item as Record<string, unknown>;
    if (typeof id !== "string" || id.length === 0 || typeof lastSeenAt !== "number") continue;
    accounts.push({
      id,
      email: typeof email === "string" ? email : null,
      displayName: typeof displayName === "string" ? displayName : null,
      // Only an https image is shown; anything else falls back to initials.
      profileImageUrl: typeof profileImageUrl === "string" && profileImageUrl.startsWith("https://") ? profileImageUrl : null,
      signInMethod: typeof signInMethod === "string" && /^[a-z0-9-]+$/.test(signInMethod) ? signInMethod : null,
      hasPassword: hasPassword === true,
      lastSeenAt,
    });
  }
  return accounts.sort((a, b) => b.lastSeenAt - a.lastSeenAt).slice(0, ACCOUNT_HISTORY_LIMIT);
}

/**
 * Puts the account first, replacing any older entry for the same id. A
 * sign-in method that is not known yet keeps the one already recorded.
 */
export function rememberAccount(
  history: RememberedAccount[],
  account: Omit<RememberedAccount, "lastSeenAt">,
  now: number = Date.now(),
): RememberedAccount[] {
  const previous = history.find((entry) => entry.id === account.id);
  const rest = history.filter((entry) => entry.id !== account.id);
  const signInMethod = account.signInMethod === undefined ? previous?.signInMethod ?? null : account.signInMethod;
  const hasPassword = account.hasPassword === undefined ? previous?.hasPassword ?? false : account.hasPassword;
  return [{ ...account, signInMethod, hasPassword, lastSeenAt: now }, ...rest].slice(0, ACCOUNT_HISTORY_LIMIT);
}

/** The provider a remembered account signs in with, if the project still offers it. */
export function rememberedSignInProvider(account: RememberedAccount, enabledProviders: readonly string[]): string | null {
  return account.signInMethod && enabledProviders.includes(account.signInMethod) ? account.signInMethod : null;
}

/** Of an account's linked providers, the one to remember: project order first. */
export function preferredSignInMethod(
  linked: readonly { type: string; allowSignIn: boolean }[],
  enabledProviders: readonly string[],
): string | null {
  const usable = new Set(linked.filter((provider) => provider.allowSignIn).map((provider) => provider.type));
  return enabledProviders.find((id) => usable.has(id)) ?? null;
}

export function forgetAccount(history: RememberedAccount[], id: string): RememberedAccount[] {
  return history.filter((entry) => entry.id !== id);
}

/** The chooser's other rows: every remembered account except the signed-in one. */
export function otherAccounts(history: RememberedAccount[], currentId: string): RememberedAccount[] {
  return history.filter((entry) => entry.id !== currentId && entry.email);
}

// MARK: Hosted error pages

/**
 * Where a failed OAuth return should land instead of the hosted error page,
 * which prints raw service codes off-centre. Only a cmux code is passed on:
 * the provider's text never reaches the page.
 *
 * - `/handler/oauth-callback?error=...` (the provider or service refused)
 * - `/handler/error?errorCode=...` (the service's own error redirect)
 */
export function hostedAuthErrorRedirect(
  page: string | undefined,
  params: { get(name: string): string | null },
): string | null {
  let failed = false;
  let detail = "";
  if (page === "oauth-callback" && params.get("error")) {
    failed = true;
    detail = `${params.get("error") ?? ""} ${params.get("error_description") ?? ""}`;
  } else if (page === "error" && params.get("errorCode")) {
    failed = true;
    detail = params.get("errorCode") ?? "";
  }
  if (!failed) return null;
  const emailInUse =
    /CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE/.test(detail) ||
    /already used for authentication by another account/i.test(detail);
  return emailInUse ? "/handler/auth-error?code=email-unverified" : "/handler/auth-error";
}

// MARK: How a remembered account signs in

/**
 * The provider a remembered account goes straight to, or null for the form.
 * An account with a password always gets the form (it may also have a
 * provider linked that does not sign it in); an account with no password
 * goes to its linked provider, like Gmail's account list.
 */
export function rememberedMethodFor(input: {
  hasPassword: boolean;
  linked: readonly { type: string; allowSignIn: boolean }[];
  preference: readonly string[];
}): string | null {
  if (input.hasPassword) return null;
  return preferredSignInMethod(input.linked, input.preference);
}

/**
 * Providers that take the OpenID Connect `login_hint`: given a remembered
 * account's email they go straight to that account ("Continue as ...")
 * instead of their own account chooser. GitHub's equivalent wants a
 * username, which isn't kept; Apple has none.
 */
const LOGIN_HINT_PROVIDERS = new Set(["google", "microsoft"]);

/** The hint to send a provider for a known account, or null for none. */
export function oauthLoginHint(provider: string, email: string | null | undefined): string | null {
  const address = email?.trim();
  return address && LOGIN_HINT_PROVIDERS.has(provider) && address.includes("@") ? address : null;
}

/**
 * Recorded just before a remembered account leaves for its provider, so a
 * failed return can send that account to the form next time.
 */
export const PENDING_OAUTH_KEY = "cmux.signIn.pendingOAuth";
export const PENDING_OAUTH_MAX_AGE_MS = 10 * 60 * 1000;

export function serializePendingOAuth(accountId: string, now: number = Date.now()): string {
  return JSON.stringify({ accountId, at: now });
}

export function parsePendingOAuth(raw: string | null, now: number = Date.now()): string | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as { accountId?: unknown; at?: unknown };
    if (typeof value.accountId !== "string" || typeof value.at !== "number") return null;
    const age = now - value.at;
    return age >= 0 && age <= PENDING_OAUTH_MAX_AGE_MS ? value.accountId : null;
  } catch {
    return null;
  }
}

/** A remembered account whose direct sign-in failed opens the form next time. */
export function demoteRememberedMethod(history: RememberedAccount[], accountId: string): RememberedAccount[] {
  return history.map((entry) => (entry.id === accountId ? { ...entry, signInMethod: null } : entry));
}
