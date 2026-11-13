import { beforeAll, describe, expect, test } from "bun:test";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWK, type JWTVerifyGetKey } from "jose";

import {
  CHATGPT_ISSUER,
  chatGPTRedirectURI,
  finishChatGPTLink,
  finishChatGPTSignIn,
  startChatGPTSignIn,
  type ChatGPTAccountUser,
  type ChatGPTAccounts,
  type ChatGPTLink,
  type ChatGPTSignInSettings,
} from "../app/handler/chatgpt/chatgpt-sign-in";

const ORIGIN = "https://cmux.com";
const CLIENT_ID = "oaiapp_test";
const RETURN_TO = "/handler/sign-in?after_auth_return_to=%2Fhandler%2Fafter-sign-in&cmux_continue=1";

let privateKey: CryptoKey;
let keys: JWTVerifyGetKey;
let otherPrivateKey: CryptoKey;

beforeAll(async () => {
  const pair = await generateKeyPair("RS256", { extractable: true });
  privateKey = pair.privateKey;
  const jwk: JWK = { ...(await exportJWK(pair.publicKey)), kid: "k1", alg: "RS256", use: "sig" };
  keys = createLocalJWKSet({ keys: [jwk] });
  otherPrivateKey = (await generateKeyPair("RS256")).privateKey;
});

type TokenRequest = { url: string; body: URLSearchParams; authorization: string | null };

function settings(overrides: Partial<ChatGPTSignInSettings> = {}, idToken: () => Promise<string> = () => token({}), requests: TokenRequest[] = []): ChatGPTSignInSettings {
  return {
    clientId: CLIENT_ID,
    clientSecret: null,
    keys,
    sealKey: new Uint8Array(32).fill(7),
    now: () => Date.now(),
    fetch: async (input, init) => {
      requests.push({
        url: String(input),
        body: new URLSearchParams(String(init?.body ?? "")),
        authorization: new Headers(init?.headers).get("authorization"),
      });
      return Response.json({ id_token: await idToken(), access_token: "at", token_type: "Bearer" });
    },
    ...overrides,
  };
}

let currentNonce = "";

async function token(claims: Record<string, unknown>, options: { key?: CryptoKey; issuer?: string; audience?: string; nonce?: string } = {}): Promise<string> {
  return new SignJWT({ email: "ada@example.com", email_verified: true, name: "Ada", nonce: options.nonce ?? currentNonce, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "k1" })
    .setIssuer(options.issuer ?? CHATGPT_ISSUER)
    .setAudience(options.audience ?? CLIENT_ID)
    .setSubject("user-sub-1")
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(options.key ?? privateKey);
}

class FakeAccounts implements ChatGPTAccounts {
  users: ({ -readonly [K in keyof ChatGPTAccountUser]: ChatGPTAccountUser[K] } & { name?: string | null })[] = [];
  current: string | null = null;
  signedIn: string[] = [];
  takenEmails = new Set<string>();
  async currentUser() {
    return this.users.find((user) => user.id === this.current) ?? null;
  }
  async findByEmail(email: string) {
    return this.users.find((user) => user.primaryEmail?.toLowerCase() === email.toLowerCase()) ?? null;
  }
  async create(input: { email: string; name: string | null; link: ChatGPTLink }) {
    if (this.takenEmails.has(input.email)) return "email-taken" as const;
    const user = { id: `u${this.users.length + 1}`, primaryEmail: input.email, primaryEmailVerified: true, chatgpt: input.link, name: input.name };
    this.users.push(user);
    return { id: user.id };
  }
  async link(userId: string, link: ChatGPTLink) {
    const user = this.users.find((candidate) => candidate.id === userId);
    if (user) user.chatgpt = link;
  }
  async signIn(userId: string) {
    this.signedIn.push(userId);
  }
}

/** Starts a sign-in and returns the state the callback needs. */
async function begin(config: ChatGPTSignInSettings, returnTo: string | null = RETURN_TO) {
  const started = await startChatGPTSignIn(config, { origin: ORIGIN, returnTo });
  const authorize = new URL(started.redirect);
  currentNonce = authorize.searchParams.get("nonce") ?? "";
  return { started, authorize, state: authorize.searchParams.get("state") ?? "" };
}

function callback(config: ChatGPTSignInSettings, accounts: ChatGPTAccounts, transaction: string | null, query: Record<string, string>) {
  return finishChatGPTSignIn(config, accounts, {
    origin: ORIGIN,
    query: new URLSearchParams(query),
    transactionCookie: transaction,
  });
}

describe("Sign in with ChatGPT: start", () => {
  test("sends the browser to OpenAI with PKCE, state, nonce and identity scopes only", async () => {
    const { authorize, started } = await begin(settings());
    expect(`${authorize.origin}${authorize.pathname}`).toBe("https://auth.openai.com/api/accounts/authorize");
    const params = authorize.searchParams;
    expect(params.get("client_id")).toBe(CLIENT_ID);
    expect(params.get("redirect_uri")).toBe(chatGPTRedirectURI(ORIGIN));
    expect(params.get("redirect_uri")).toBe("https://cmux.com/handler/chatgpt/callback");
    expect(params.get("response_type")).toBe("code");
    expect(params.get("scope")).toBe("openid profile email");
    expect(params.get("code_challenge_method")).toBe("S256");
    expect(params.get("code_challenge")?.length).toBe(43);
    expect(params.get("state")?.length).toBeGreaterThanOrEqual(32);
    expect(params.get("nonce")?.length).toBeGreaterThanOrEqual(32);
    // The verifier stays server-side: only the sealed cookie carries it.
    expect(started.redirect).not.toContain(started.transactionCookie);
    expect(started.transactionCookie.length).toBeGreaterThan(40);
  });

  test("every start is fresh", async () => {
    const config = settings();
    const a = await begin(config);
    const b = await begin(config);
    expect(a.state).not.toBe(b.state);
    expect(a.authorize.searchParams.get("nonce")).not.toBe(b.authorize.searchParams.get("nonce"));
    expect(a.authorize.searchParams.get("code_challenge")).not.toBe(b.authorize.searchParams.get("code_challenge"));
  });
});

describe("Sign in with ChatGPT: callback", () => {
  test("a new person gets a cmux account linked to their ChatGPT identity and is signed in", async () => {
    const requests: TokenRequest[] = [];
    const config = settings({}, () => token({}), requests);
    const accounts = new FakeAccounts();
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "the-code", state });
    expect(outcome).toEqual({ kind: "signed-in", returnTo: RETURN_TO });
    expect(accounts.users).toHaveLength(1);
    expect(accounts.users[0]?.primaryEmail).toBe("ada@example.com");
    expect(accounts.users[0]?.chatgpt).toEqual({ iss: CHATGPT_ISSUER, aud: CLIENT_ID, sub: "user-sub-1" });
    expect(accounts.signedIn).toEqual(["u1"]);
    // The code is redeemed with the original verifier, redirect URI and a public client.
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe("https://auth.openai.com/api/accounts/oauth/token");
    expect(requests[0]?.body.get("grant_type")).toBe("authorization_code");
    expect(requests[0]?.body.get("code")).toBe("the-code");
    expect(requests[0]?.body.get("redirect_uri")).toBe("https://cmux.com/handler/chatgpt/callback");
    expect(requests[0]?.body.get("client_id")).toBe(CLIENT_ID);
    expect(requests[0]?.body.get("code_verifier")?.length).toBeGreaterThanOrEqual(43);
    expect(requests[0]?.body.has("client_secret")).toBe(false);
    expect(requests[0]?.authorization).toBeNull();
  });

  test("a confidential client authenticates with HTTP Basic, never in the form body", async () => {
    const requests: TokenRequest[] = [];
    const config = settings({ clientSecret: "s3cret" }, () => token({}), requests);
    const { started, state } = await begin(config);
    await callback(config, new FakeAccounts(), started.transactionCookie, { code: "c", state });
    expect(requests[0]?.authorization).toBe(`Basic ${btoa(`${CLIENT_ID}:s3cret`)}`);
    expect(requests[0]?.body.has("client_secret")).toBe(false);
  });

  test("a returning person whose account carries the same ChatGPT identity signs in", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: true, chatgpt: { iss: CHATGPT_ISSUER, aud: CLIENT_ID, sub: "user-sub-1" } });
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome).toEqual({ kind: "signed-in", returnTo: RETURN_TO });
    expect(accounts.signedIn).toEqual(["u9"]);
    expect(accounts.users).toHaveLength(1);
  });

  test("an email match alone never signs into an existing account: it asks for the usual sign-in first", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: true, chatgpt: null });
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome.kind).toBe("link-required");
    if (outcome.kind !== "link-required") throw new Error("unreachable");
    expect(accounts.signedIn).toEqual([]);
    expect(accounts.users[0]?.chatgpt).toBeNull();
    const errorURL = new URL(outcome.redirect, ORIGIN);
    expect(errorURL.pathname).toBe("/handler/auth-error");
    expect(errorURL.searchParams.get("code")).toBe("chatgpt-link");
    // Back to sign in goes on to the link step, which returns to the original target.
    const linkURL = new URL(errorURL.searchParams.get("after_auth_return_to") ?? "", ORIGIN);
    expect(linkURL.pathname).toBe("/handler/chatgpt/link");
    expect(linkURL.searchParams.get("return_to")).toBe(RETURN_TO);
    expect(outcome.pendingLinkCookie.length).toBeGreaterThan(40);
  });

  test("an account another ChatGPT identity owns is refused", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: true, chatgpt: { iss: CHATGPT_ISSUER, aud: CLIENT_ID, sub: "someone-else" } });
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome.kind).toBe("failed");
    expect(accounts.signedIn).toEqual([]);
  });

  test("the person already signed in to the matching account links ChatGPT at once", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "Ada@Example.com", primaryEmailVerified: true, chatgpt: null });
    accounts.current = "u9";
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome).toEqual({ kind: "signed-in", returnTo: RETURN_TO });
    expect(accounts.users[0]?.chatgpt).toEqual({ iss: CHATGPT_ISSUER, aud: CLIENT_ID, sub: "user-sub-1" });
  });

  test("an email OpenAI has not verified creates nothing", async () => {
    const config = settings({}, () => token({ email_verified: false }));
    const accounts = new FakeAccounts();
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome.kind).toBe("failed");
    if (outcome.kind !== "failed") throw new Error("unreachable");
    expect(new URL(outcome.redirect, ORIGIN).searchParams.get("code")).toBe("chatgpt-email-unverified");
    expect(accounts.users).toHaveLength(0);
    expect(accounts.signedIn).toEqual([]);
  });

  test("an email Stack already uses for another sign-in asks for the usual sign-in", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.takenEmails.add("ada@example.com");
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome.kind).toBe("link-required");
  });

  const rejected: [string, () => Promise<string>][] = [
    ["a token signed by another key", () => token({}, { key: otherPrivateKey })],
    ["a token from another issuer", () => token({}, { issuer: "https://evil.example" })],
    ["a token for another client", () => token({}, { audience: "oaiapp_other" })],
    ["a token with another nonce", () => token({}, { nonce: "not-the-nonce" })],
  ];
  for (const [name, idToken] of rejected) {
    test(`${name} is refused`, async () => {
      const config = settings({}, idToken);
      const accounts = new FakeAccounts();
      const { started, state } = await begin(config);
      const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
      expect(outcome.kind).toBe("failed");
      expect(accounts.users).toHaveLength(0);
      expect(accounts.signedIn).toEqual([]);
    });
  }

  test("a callback whose state does not match the transaction never redeems the code", async () => {
    const requests: TokenRequest[] = [];
    const config = settings({}, () => token({}), requests);
    const { started } = await begin(config);
    const outcome = await callback(config, new FakeAccounts(), started.transactionCookie, { code: "c", state: "forged" });
    expect(outcome.kind).toBe("failed");
    expect(requests).toHaveLength(0);
  });

  test("a callback with no transaction, a tampered one or an expired one is refused before redeeming", async () => {
    const requests: TokenRequest[] = [];
    let now = Date.now();
    const config = settings({ now: () => now }, () => token({}), requests);
    const { started, state } = await begin(config);
    expect((await callback(config, new FakeAccounts(), null, { code: "c", state })).kind).toBe("failed");
    const tampered = `${started.transactionCookie.slice(0, -4)}AAAA`;
    expect((await callback(config, new FakeAccounts(), tampered, { code: "c", state })).kind).toBe("failed");
    now += 11 * 60_000;
    expect((await callback(config, new FakeAccounts(), started.transactionCookie, { code: "c", state })).kind).toBe("failed");
    expect(requests).toHaveLength(0);
  });

  test("cancelling at OpenAI returns to the form without the continue marker", async () => {
    const config = settings();
    const { started, state } = await begin(config);
    const outcome = await callback(config, new FakeAccounts(), started.transactionCookie, { error: "access_denied", state });
    expect(outcome.kind).toBe("cancelled");
    if (outcome.kind !== "cancelled") throw new Error("unreachable");
    const url = new URL(outcome.redirect, ORIGIN);
    expect(url.pathname).toBe("/handler/sign-in");
    expect(url.searchParams.get("after_auth_return_to")).toBe("/handler/after-sign-in");
    expect(url.searchParams.has("cmux_continue")).toBe(false);
  });

  test("a return target on another origin is dropped", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    const { started, state } = await begin(config, "https://evil.example/steal");
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    expect(outcome).toEqual({ kind: "signed-in", returnTo: "/" });
  });
});

describe("Sign in with ChatGPT: link after the usual sign-in", () => {
  async function pendingLink(config: ChatGPTSignInSettings, accounts: FakeAccounts) {
    const { started, state } = await begin(config);
    const outcome = await callback(config, accounts, started.transactionCookie, { code: "c", state });
    if (outcome.kind !== "link-required") throw new Error(`expected link-required, got ${outcome.kind}`);
    return outcome.pendingLinkCookie;
  }

  test("links when the signed-in account owns the ChatGPT email", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: true, chatgpt: null });
    const cookie = await pendingLink(config, accounts);
    accounts.current = "u9";
    const result = await finishChatGPTLink(config, accounts, { origin: ORIGIN, pendingLinkCookie: cookie, returnTo: RETURN_TO });
    expect(result).toEqual({ linked: true, returnTo: RETURN_TO });
    expect(accounts.users[0]?.chatgpt).toEqual({ iss: CHATGPT_ISSUER, aud: CLIENT_ID, sub: "user-sub-1" });
  });

  test("never links to a different signed-in account", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: true, chatgpt: null });
    accounts.users.push({ id: "u10", primaryEmail: "mallory@example.com", primaryEmailVerified: true, chatgpt: null });
    const cookie = await pendingLink(config, accounts);
    accounts.current = "u10";
    const result = await finishChatGPTLink(config, accounts, { origin: ORIGIN, pendingLinkCookie: cookie, returnTo: RETURN_TO });
    expect(result.linked).toBe(false);
    expect(accounts.users.every((user) => user.chatgpt === null)).toBe(true);
  });

  test("never links an account whose email is unverified", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    accounts.users.push({ id: "u9", primaryEmail: "ada@example.com", primaryEmailVerified: false, chatgpt: null });
    const cookie = await pendingLink(config, accounts);
    accounts.current = "u9";
    const result = await finishChatGPTLink(config, accounts, { origin: ORIGIN, pendingLinkCookie: cookie, returnTo: RETURN_TO });
    expect(result.linked).toBe(false);
  });

  test("without a pending link it just continues", async () => {
    const config = settings();
    const accounts = new FakeAccounts();
    const result = await finishChatGPTLink(config, accounts, { origin: ORIGIN, pendingLinkCookie: null, returnTo: "https://evil.example/" });
    expect(result).toEqual({ linked: false, returnTo: "/" });
  });
});
