import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID = "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY = "test-publishable-key";
process.env.STACK_SECRET_SERVER_KEY = "test-secret-key";

const {
  ACCOUNT_HISTORY_LIMIT,
  forgetAccount,
  otherAccounts,
  parseAccountHistory,
  preferredSignInMethod,
  rememberAccount,
  rememberedSignInProvider,
  rememberedMethodFor,
  demoteRememberedMethod,
  parsePendingOAuth,
  serializePendingOAuth,
  PENDING_OAUTH_MAX_AGE_MS,
  CONTINUE_PARAM,
  SELECT_ACCOUNT_PROMPT,
  accountInitials,
  handlerHref,
  hostedAuthErrorRedirect,
  isReturningFromOAuth,
  oauthLoginHint,
  signInEntry,
  signInIsForApp,
  signUpPendingHref,
  oauthReturnTo,
} = await import("../app/handler/sign-in-entry");
const { GET: startNativeSignIn } = await import("../app/handler/native-sign-in/route");

const signedIn = { hasUser: true, isRestricted: false, prompt: null, returningFromOAuth: false };

describe("sign-in entry", () => {
  test("a signed-out browser with no remembered accounts gets the form", () => {
    expect(signInEntry({ ...signedIn, hasUser: false })).toBe("form");
    expect(signInEntry({ ...signedIn, hasUser: false, prompt: SELECT_ACCOUNT_PROMPT })).toBe("form");
  });

  // Like Gmail: the accounts this browser used come first, signed in or not.
  test("a signed-out browser that has signed in before lists those accounts", () => {
    const signedOut = { ...signedIn, hasUser: false, hasRememberedAccounts: true };
    expect(signInEntry(signedOut)).toBe("choose-account");
    expect(signInEntry({ ...signedOut, chooseWhenSignedOut: false })).toBe("form");
    // A failed OAuth return lands signed out; it gets the form, not the list again.
    expect(signInEntry({ ...signedOut, returningFromOAuth: true })).toBe("form");
  });

  test("a signed-in arrival continues by default", () => {
    expect(signInEntry(signedIn)).toBe("continue");
  });

  test("the app's select_account prompt shows the chooser", () => {
    expect(signInEntry({ ...signedIn, prompt: SELECT_ACCOUNT_PROMPT })).toBe("choose-account");
    expect(signInEntry({ ...signedIn, prompt: "login" })).toBe("continue");
  });

  // Austin's case: sign out in the app, sign in again. The browser is still
  // signed in, so without this it hands the same account straight back.
  test("a sign-in for the Mac app confirms the account", () => {
    expect(signInEntry({ ...signedIn, forApp: true })).toBe("choose-account");
    expect(signInEntry({ ...signedIn, forApp: true, returningFromOAuth: true })).toBe("continue");
    expect(signInEntry({ ...signedIn, forApp: true, isRestricted: true })).toBe("onboarding");
  });

  test("an account signed in on this page just now is not asked again", () => {
    expect(signInEntry({ ...signedIn, forApp: true, signedInHere: true })).toBe("continue");
    expect(signInEntry({ ...signedIn, prompt: SELECT_ACCOUNT_PROMPT, signedInHere: true })).toBe("continue");
  });

  test("every signed-in arrival confirms when that policy is on", () => {
    expect(signInEntry({ ...signedIn, chooseOnEverySignedInArrival: true })).toBe("choose-account");
  });

  // OAuth lands back on this page signed in, with the same query. If the
  // chooser won here, every Google, GitHub and Apple login would stall.
  test("the end of an OAuth login started here always continues", () => {
    expect(signInEntry({ ...signedIn, prompt: SELECT_ACCOUNT_PROMPT, returningFromOAuth: true })).toBe("continue");
    expect(
      signInEntry({ ...signedIn, returningFromOAuth: true, chooseOnEverySignedInArrival: true }),
    ).toBe("continue");
  });

  test("a restricted account goes to onboarding before any chooser", () => {
    expect(signInEntry({ ...signedIn, isRestricted: true, prompt: SELECT_ACCOUNT_PROMPT })).toBe("onboarding");
  });
});

describe("sign-ins for the Mac app", () => {
  const appCallback = "cmux://auth-callback?cmux_auth_state=state-123";
  const afterSignIn = (callback: string) => `/handler/after-sign-in?native_app_return_to=${encodeURIComponent(callback)}`;

  test("an app attempt's return target counts, relative or absolute", () => {
    expect(signInIsForApp(afterSignIn(appCallback))).toBe(true);
    expect(signInIsForApp(`https://cmux.com${afterSignIn(appCallback)}`)).toBe(true);
    expect(signInIsForApp(`${afterSignIn(appCallback)}&cmux_auth_handoff=nonce`)).toBe(true);
  });

  test("web sign-ins, the pricing webview and malformed targets do not", () => {
    expect(signInIsForApp(null)).toBe(false);
    expect(signInIsForApp("/dashboard")).toBe(false);
    expect(signInIsForApp(afterSignIn("cmux://auth-callback"))).toBe(false);
    expect(signInIsForApp(`/dashboard?native_app_return_to=${encodeURIComponent(appCallback)}`)).toBe(false);
    expect(signInIsForApp(afterSignIn("not a url"))).toBe(false);
  });
});

describe("OAuth return marker", () => {
  const page = "https://cmux.test/handler/sign-in?after_auth_return_to=%2Fdashboard&prompt=select_account";

  test("the provider returns to this page with the marker, other params kept", () => {
    const returnTo = oauthReturnTo(`${page}#top`);
    expect(returnTo).toBeDefined();
    const marked = new URL(returnTo!);
    expect(marked.searchParams.get(CONTINUE_PARAM)).toBe("1");
    expect(marked.searchParams.get("after_auth_return_to")).toBe("/dashboard");
    expect(marked.searchParams.get("prompt")).toBe(SELECT_ACCOUNT_PROMPT);
    expect(marked.hash).toBe("");
    expect(isReturningFromOAuth(marked.searchParams)).toBe(true);
  });

  test("a page with no return target leaves the provider's default return", () => {
    expect(oauthReturnTo("https://cmux.test/handler/sign-in")).toBeUndefined();
    expect(oauthReturnTo("https://cmux.test/handler/sign-in?prompt=select_account")).toBeUndefined();
  });

  test("only the exact marker value counts", () => {
    expect(isReturningFromOAuth(new URLSearchParams(`${CONTINUE_PARAM}=0`))).toBe(false);
    expect(isReturningFromOAuth(new URLSearchParams(""))).toBe(false);
  });
});

describe("links that keep the return target", () => {
  test("sign-in, sign-up and forgot-password carry only after_auth_return_to", () => {
    expect(handlerHref("sign-up", "/dashboard?team=t1")).toBe("/handler/sign-up?after_auth_return_to=%2Fdashboard%3Fteam%3Dt1");
    expect(handlerHref("forgot-password", null)).toBe("/handler/forgot-password");
  });

  test("password sign-up waits on the pending page with all three return params", () => {
    const current = new URL(
      "https://cmux.test/handler/sign-up?after_auth_return_to=%2Fa&web_return_to=%2Fb&native_app_return_to=cmux%3A%2F%2Fauth-callback&other=x",
    );
    const pending = new URL(signUpPendingHref(current));
    expect(pending.pathname).toBe("/handler/auth-error");
    expect(pending.searchParams.get("code")).toBe("signup-pending");
    expect(pending.searchParams.get("after_auth_return_to")).toBe("/a");
    expect(pending.searchParams.get("web_return_to")).toBe("/b");
    expect(pending.searchParams.get("native_app_return_to")).toBe("cmux://auth-callback");
    expect(pending.searchParams.has("other")).toBe(false);
  });

  test("initials come from the name, then the email", () => {
    expect(accountInitials("Lucas Ribeiro", "lucas@cmux.com")).toBe("LR");
    expect(accountInitials(null, "lucas@cmux.com")).toBe("LU");
    expect(accountInitials("  ", null)).toBe("?");
  });
});

describe("native sign-in prompt", () => {
  const afterSignIn = "/handler/after-sign-in?native_app_return_to=cmux%3A%2F%2Fauth-callback%3Fcmux_auth_state%3Dstate-123";

  function start(extra: string) {
    const url = `https://cmux.test/handler/native-sign-in?after_auth_return_to=${encodeURIComponent(afterSignIn)}${extra}`;
    return startNativeSignIn(new NextRequest(url, { headers: { "sec-fetch-site": "none" } }));
  }

  test("passes select_account through to the sign-in page", () => {
    const location = new URL(start(`&prompt=${SELECT_ACCOUNT_PROMPT}`).headers.get("location")!);
    expect(location.pathname).toBe("/handler/sign-in");
    expect(location.searchParams.get("prompt")).toBe(SELECT_ACCOUNT_PROMPT);
  });

  test("drops any other prompt value", () => {
    const location = new URL(start("&prompt=none").headers.get("location")!);
    expect(location.searchParams.has("prompt")).toBe(false);
  });
});

describe("accounts this browser has used", () => {
  const a = { id: "a", email: "a@cmux.com", displayName: "Ada" };
  const b = { id: "b", email: "b@cmux.com", displayName: null };

  test("the newest sign-in comes first and an account appears once", () => {
    let history = rememberAccount([], a, 1);
    history = rememberAccount(history, b, 2);
    history = rememberAccount(history, a, 3);
    expect(history.map((entry) => entry.id)).toEqual(["a", "b"]);
    expect(history[0].lastSeenAt).toBe(3);
  });

  test("the list is capped", () => {
    let history = parseAccountHistory(null);
    for (let index = 0; index < ACCOUNT_HISTORY_LIMIT + 3; index += 1) {
      history = rememberAccount(history, { id: `u${index}`, email: `u${index}@cmux.com`, displayName: null }, index);
    }
    expect(history).toHaveLength(ACCOUNT_HISTORY_LIMIT);
    expect(history[0].id).toBe(`u${ACCOUNT_HISTORY_LIMIT + 2}`);
  });

  test("removing an account and listing the others", () => {
    const history = rememberAccount(rememberAccount([], a, 1), b, 2);
    expect(forgetAccount(history, "a").map((entry) => entry.id)).toEqual(["b"]);
    expect(otherAccounts(history, "b").map((entry) => entry.id)).toEqual(["a"]);
    // A name is enough to show the row; with neither name nor email there's nothing to show.
    expect(otherAccounts([{ id: "c", email: null, displayName: "No email", lastSeenAt: 1 }], "a").map((entry) => entry.id)).toEqual(["c"]);
    expect(otherAccounts([{ id: "d", email: null, displayName: null, lastSeenAt: 1 }], "a")).toEqual([]);
  });

  test("a damaged or foreign stored value reads as an empty or cleaned list", () => {
    expect(parseAccountHistory("not json")).toEqual([]);
    expect(parseAccountHistory(JSON.stringify({ id: "a" }))).toEqual([]);
    expect(
      parseAccountHistory(JSON.stringify([{ id: "a", lastSeenAt: 1, email: 5 }, { nope: true }, { id: "", lastSeenAt: 2 }])),
    ).toEqual([{ id: "a", email: null, displayName: null, profileImageUrl: null, signInMethod: null, hasPassword: false, lastSeenAt: 1 }]);
    expect(
      parseAccountHistory(JSON.stringify([{ id: "a", lastSeenAt: 1, profileImageUrl: "javascript:alert(1)" }]))[0].profileImageUrl,
    ).toBeNull();
  });
});

describe("switching like Gmail", () => {
  const enabled = ["apple", "github", "google"];

  test("a remembered OAuth account goes to its provider while the project offers it", () => {
    const account = { id: "a", email: "a@cmux.com", displayName: null, signInMethod: "google", lastSeenAt: 1 };
    expect(rememberedSignInProvider(account, enabled)).toBe("google");
    expect(rememberedSignInProvider(account, ["github"])).toBeNull();
    expect(rememberedSignInProvider({ ...account, signInMethod: null }, enabled)).toBeNull();
  });

  test("the method remembered is a linked provider that may sign in, in preference order", () => {
    const linked = [
      { type: "github", allowSignIn: true },
      { type: "google", allowSignIn: true },
      { type: "apple", allowSignIn: false },
    ];
    expect(preferredSignInMethod(linked, ["google", "github", "apple"])).toBe("google");
    expect(preferredSignInMethod([{ type: "apple", allowSignIn: false }], ["google", "apple"])).toBeNull();
    expect(preferredSignInMethod([], ["google"])).toBeNull();
  });

  test("an update without a method keeps the method already known", () => {
    let history = rememberAccount([], { id: "a", email: "a@cmux.com", displayName: null, signInMethod: "github" }, 1);
    history = rememberAccount(history, { id: "a", email: "a@cmux.com", displayName: "Ada" }, 2);
    expect(history[0]).toMatchObject({ displayName: "Ada", signInMethod: "github", lastSeenAt: 2 });
    history = rememberAccount(history, { id: "a", email: "a@cmux.com", displayName: "Ada", signInMethod: null }, 3);
    expect(history[0].signInMethod).toBeNull();
  });

  test("only a plain provider id is read back from storage", () => {
    const raw = JSON.stringify([{ id: "a", lastSeenAt: 1, signInMethod: "google" }, { id: "b", lastSeenAt: 2, signInMethod: "<x>" }]);
    expect(parseAccountHistory(raw).map((entry) => entry.signInMethod)).toEqual([null, "google"]);
  });
});

describe("hosted error pages", () => {
  const q = (query: string) => new URLSearchParams(query);

  test("an email already used by another account maps to the verify-email page", () => {
    expect(hostedAuthErrorRedirect("oauth-callback", q("error=server_error&error_description=already+used+for+authentication+by+another+account"))).toBe(
      "/handler/auth-error?code=email-unverified",
    );
    expect(hostedAuthErrorRedirect("error", q("errorCode=CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE"))).toBe(
      "/handler/auth-error?code=email-unverified",
    );
  });

  test("any other failure maps to the generic page, and a normal return is left alone", () => {
    expect(hostedAuthErrorRedirect("oauth-callback", q("error=access_denied"))).toBe("/handler/auth-error");
    expect(hostedAuthErrorRedirect("oauth-callback", q("code=abc&state=xyz"))).toBeNull();
    // The return target survives, so "back to sign in" still finishes the original sign-in.
    const kept = new URL(hostedAuthErrorRedirect("error", q("errorCode=X&after_auth_return_to=%2Fdashboard&other=1"))!, "https://cmux.test");
    expect(kept.searchParams.get("after_auth_return_to")).toBe("/dashboard");
    expect(kept.searchParams.has("other")).toBe(false);
    expect(hostedAuthErrorRedirect("sign-in", q("error=x"))).toBeNull();
  });
});

describe("which remembered accounts go straight to a provider", () => {
  const preference = ["google", "github", "apple"];
  const google = [{ type: "google", allowSignIn: true }];

  test("a Google-only account goes to Google", () => {
    expect(rememberedMethodFor({ linked: google, preference })).toBe("google");
  });

  // A Google account that later set a password used to open the password form.
  test("a Google account that also has a password still goes to Google", () => {
    const signedUpWithGoogle = { linked: google, preference, hasPassword: true };
    expect(rememberedMethodFor(signedUpWithGoogle)).toBe("google");
    expect(rememberedMethodFor({ ...signedUpWithGoogle, usedProvider: "google" })).toBe("google");
  });

  test("the provider this sign-in came back from wins over the preference order", () => {
    const both = [{ type: "google", allowSignIn: true }, { type: "github", allowSignIn: true }];
    expect(rememberedMethodFor({ linked: both, preference, usedProvider: "github" })).toBe("github");
    expect(rememberedMethodFor({ linked: both, preference })).toBe("google");
  });

  test("a provider that can't sign the account in is never picked", () => {
    const connectedOnly = [{ type: "google", allowSignIn: false }];
    expect(rememberedMethodFor({ linked: connectedOnly, preference })).toBeNull();
    expect(rememberedMethodFor({ linked: connectedOnly, preference, usedProvider: "google" })).toBeNull();
    // A stale "last used" from another account doesn't count either.
    expect(rememberedMethodFor({ linked: google, preference, usedProvider: "github" })).toBe("google");
  });

  test("an email account with no provider gets the form", () => {
    expect(rememberedMethodFor({ linked: [], preference })).toBeNull();
  });

  test("a failed direct sign-in sends only that account to the form next time", () => {
    const history = [
      { id: "a", email: "a@x.com", displayName: null, signInMethod: "google", lastSeenAt: 2 },
      { id: "b", email: "b@x.com", displayName: null, signInMethod: "github", lastSeenAt: 1 },
    ];
    expect(demoteRememberedMethod(history, "a").map((entry) => entry.signInMethod)).toEqual([null, "github"]);
  });

  test("the pending marker names the account only while fresh", () => {
    const raw = serializePendingOAuth("a", 1_000);
    expect(parsePendingOAuth(raw, 2_000)).toBe("a");
    expect(parsePendingOAuth(raw, 1_000 + PENDING_OAUTH_MAX_AGE_MS + 1)).toBeNull();
    expect(parsePendingOAuth("nope", 2_000)).toBeNull();
  });
});

describe("password accounts", () => {
  test("having a password is remembered and kept when an update does not say", () => {
    let history = rememberAccount([], { id: "a", email: "a@x.com", displayName: null, hasPassword: true }, 1);
    history = rememberAccount(history, { id: "a", email: "a@x.com", displayName: "A" }, 2);
    expect(history[0].hasPassword).toBe(true);
    expect(parseAccountHistory(JSON.stringify(history))[0].hasPassword).toBe(true);
  });
});

describe("login hint for a remembered account", () => {
  test("Google and Microsoft get the account's email; others get none", () => {
    expect(oauthLoginHint("google", " lucas@example.com ")).toBe("lucas@example.com");
    expect(oauthLoginHint("microsoft", "lucas@example.com")).toBe("lucas@example.com");
    expect(oauthLoginHint("github", "lucas@example.com")).toBeNull();
    expect(oauthLoginHint("apple", "lucas@example.com")).toBeNull();
  });

  test("no usable email, no hint", () => {
    expect(oauthLoginHint("google", null)).toBeNull();
    expect(oauthLoginHint("google", "  ")).toBeNull();
    expect(oauthLoginHint("google", "not-an-email")).toBeNull();
  });
});

describe("switch account from the dashboard", () => {
  test("opens the chooser and comes back to the dashboard through after-sign-in", async () => {
    const { vaultSwitchAccountHref } = await import("../app/lib/vault-auth");
    const href = new URL(vaultSwitchAccountHref("/en/dashboard"), "https://cmux.test");
    expect(href.pathname).toBe("/handler/sign-in");
    expect(href.searchParams.get("prompt")).toBe(SELECT_ACCOUNT_PROMPT);
    const afterSignIn = new URL(href.searchParams.get("after_auth_return_to")!, "https://cmux.test");
    expect(afterSignIn.pathname).toBe("/handler/after-sign-in");
    expect(afterSignIn.searchParams.get("after_auth_return_to")).toBe("/en/dashboard");
    expect(signInEntry({ ...signedIn, prompt: href.searchParams.get("prompt") })).toBe("choose-account");
  });
});
