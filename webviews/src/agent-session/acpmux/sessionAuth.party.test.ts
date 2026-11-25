// The composer's sign-in notice names who refused the chat and offers the one fix that works (user,
// Nov 19, a DeepSeek V4.1 Flash chat on OpenCode Go: "bad error message, hard to tell if cmux is signed
// out or the model provider is signed out"). The notice read "Your sign-in expired. Sign in again to
// continue. · its last turn failed: Internal error: This API key has expired." and its model chip
// said "Sign in again", which never renews a provider's API key.
import { expect, test } from "bun:test";
import { translate } from "./i18n";
import {
  authChipText,
  authLoginText,
  authText,
  canSessionLogin,
  readSessionAuth,
  sessionLogin,
  type SessionAuth,
} from "./sessionAuth";

const OPENCODE_DETAIL =
  "its last turn failed: Internal error: This API key has expired. Create a new API key in OpenCode Console and replace it in your client or secret store.";
const local = { host: null, login: { kind: "terminal" as const, command: "opencode auth login", host: null } };

const cases: { name: string; auth: SessionAuth; words: string; fix: string }[] = [
  {
    name: "the user's case: OpenCode Go expired its API key",
    auth: {
      state: "expired",
      source: "turn",
      evidenceAt: 1,
      harness: "opencode",
      detail: OPENCODE_DETAIL,
      credential: "apiKey",
      provider: "opencode-go",
      ...local,
    },
    words: "Your OpenCode Go API key expired. Create a new key, then choose Replace key.",
    fix: "Replace key",
  },
  {
    name: "a provider refused an API key",
    auth: {
      state: "signedOut",
      source: "turn",
      evidenceAt: 1,
      harness: "claude",
      detail: "its last turn failed: Invalid API key · Fix external API key",
      credential: "apiKey",
      provider: "anthropic",
      ...local,
    },
    words: "Anthropic didn't accept your API key. Choose Replace key to enter a working one.",
    fix: "Replace key",
  },
  {
    name: "the agent's own sign-in expired",
    auth: {
      state: "expired",
      source: "turn",
      evidenceAt: 1,
      harness: "claude",
      detail: "its last turn failed: API Error: 401 OAuth token has expired.",
      credential: "login",
      ...local,
    },
    words: "Your Claude Code sign-in expired. Sign in to Claude Code to continue.",
    fix: "Sign in to Claude Code",
  },
  {
    name: "the agent is signed out",
    auth: { state: "signedOut", source: "authCheck", evidenceAt: 1, harness: "codex", credential: "login", ...local },
    words: "You're signed out of Codex. Sign in to Codex to continue.",
    fix: "Sign in to Codex",
  },
  {
    name: "the person's cmux account is signed out",
    auth: {
      state: "routeAuthNeeded",
      source: "routeProbe",
      evidenceAt: 1,
      harness: "opencode",
      host: null,
      routeId: "cmux",
      credential: "cmux",
      login: { kind: "route", routeId: "cmux" },
    },
    words: "You're signed out of cmux. Sign in to cmux to continue.",
    fix: "Sign in to cmux",
  },
  {
    name: "an account route needs a new sign-in",
    auth: {
      state: "routeAuthNeeded",
      source: "routeProbe",
      evidenceAt: 1,
      harness: "claude",
      host: null,
      routeId: "team-route",
      login: { kind: "route", routeId: "team-route" },
    },
    words: "Your team-route account needs a new sign-in. Sign in to team-route to continue.",
    fix: "Sign in to team-route",
  },
];

for (const { name, auth, words, fix } of cases) {
  test(`${name}: the notice names it, and the chip and the button say the same fix`, () => {
    expect(authText(auth, translate)).toBe(words);
    expect(authLoginText(auth, translate)).toBe(fix);
    expect(authChipText(auth, translate)).toBe(fix);
  });
}

test("the notice never joins the daemon's diagnostic or the agent's raw error", () => {
  for (const { auth } of cases) {
    const text = authText(auth, translate)!;
    expect(text).not.toContain(" · ");
    expect(text).not.toContain("its last turn failed");
    expect(text).not.toContain("Internal error");
  }
});

test("a chat on another machine says where to sign in, as its own sentence", () => {
  const auth: SessionAuth = {
    state: "expired",
    source: "turn",
    evidenceAt: 1,
    harness: "claude",
    credential: "login",
    host: "studio-mac",
    login: { kind: "terminal", command: "claude /login", host: "studio-mac" },
  };
  expect(authText(auth, translate)).toBe(
    "Your Claude Code sign-in expired. Sign in to Claude Code to continue. On studio-mac, run claude /login.",
  );
});

test("the daemon's credential and provider are read; anything else is dropped", () => {
  const base = { state: "expired", source: "turn", evidenceAt: 1, harness: "opencode", detail: "x" };
  expect(readSessionAuth({ ...base, credential: "apiKey", provider: "opencode-go" })).toMatchObject({
    credential: "apiKey",
    provider: "opencode-go",
  });
  const odd = readSessionAuth({ ...base, credential: "password", provider: 7 });
  expect(odd.credential).toBeUndefined();
  expect(odd.provider).toBeUndefined();
});

test("Replace key runs the agent's own key entry; Sign in to cmux runs the app's sign-in, never a terminal", async () => {
  const opened: Record<string, unknown>[] = [];
  const open = async (params: Record<string, unknown>) => void opened.push(params);
  let cmux = 0;
  const signInCmux = async () => void cmux++;
  await sessionLogin(cases[0]!.auth, open, "/work", signInCmux);
  expect(opened).toEqual([{ kind: "terminal", text: "opencode auth login", cwd: "/work", run: true }]);
  expect(cmux).toBe(0);
  const signedOutOfCmux = cases.find((c) => c.auth.credential === "cmux")!.auth;
  expect(canSessionLogin(signedOutOfCmux)).toBe(true);
  await sessionLogin(signedOutOfCmux, open, "/work", signInCmux);
  expect(cmux).toBe(1);
  expect(opened).toHaveLength(1);
});

test("an answer that names no harness or route keeps the plain words: a name would be a guess", () => {
  const expired: SessionAuth = { state: "expired", source: "turn", evidenceAt: 1 };
  expect(authText(expired, translate)).toBe(translate("turn.authExpired"));
  expect(authLoginText(expired, translate)).toBe(translate("turn.signInAgain"));
  const route: SessionAuth = { state: "routeAuthNeeded", source: "routeProbe", evidenceAt: 1 };
  expect(authLoginText(route, translate)).toBe(translate("turn.signInAgain"));
});
