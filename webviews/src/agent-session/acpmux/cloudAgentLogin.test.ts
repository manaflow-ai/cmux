import { expect, test } from "bun:test";
import {
  agentLoginSupported,
  cloudAgentLogin,
  localApiKeyLogin,
  localAgentLogin,
  signsInRemotely,
  terminalSignIn,
  harnessLoginAgent,
} from "./cloudAgentLogin";
import { peerAgentLoginFromStatus } from "./environments";

type Call = [string, ...unknown[]];

/// A connected chat's login options, with a client that records what the card asks acpmux.
function options(place: { machineID?: string; elsewhere?: boolean }, harness = "claude") {
  const calls: Call[] = [];
  const client = {
    selectedSession: "chat-1",
    agentLoginStart: (agent: string, sessionId: string) => {
      calls.push(["start", agent, sessionId]);
      return Promise.resolve({ loginId: "login-1", url: "https://claude.ai/oauth/authorize", needsCode: true });
    },
    agentLoginFinish: () => Promise.resolve({ signedIn: true }),
    agentLoginApiKey: () => Promise.resolve({ saved: true }),
    agentLoginCancel: () => Promise.resolve(undefined),
    resendPrompt: () => Promise.resolve({ input: [], attachments: [] }),
    send: () => Promise.resolve(undefined),
  };
  return {
    calls,
    login: {
      connected: true,
      machineID: place.machineID,
      ...(place.elsewhere !== undefined ? { elsewhere: place.elsewhere } : {}),
      sessionId: "chat-1",
      harness,
      supported: true,
      gesture: () => Promise.resolve(undefined),
      openURL: () => undefined,
      isCurrent: (id: string) => id === "chat-1",
      currentClient: () => client as never,
    },
  };
}

test("a chat on the person's own machine (not Cloud) gets the one-click sign-in card, run on that machine", async () => {
  // Remote ergonomics scorecard, flow 2: an own machine's chat whose agent is not signed in opened a
  // terminal with the login command; the card runs the agent's own login there instead.
  const { calls, login } = options({ elsewhere: true });
  const signIn = cloudAgentLogin(login);
  expect(signIn?.agent).toBe("claude");
  // Use an API key is the card's own second way in, so no separate "this Mac" key card.
  expect(localApiKeyLogin(login)).toBeUndefined();
  await signIn!.start();
  // The start names the chat, so this Mac's acpmux forwards it to the machine the chat lives on.
  expect(calls).toEqual([["start", "claude", "chat-1"]]);
});

test("a Codex chat on another machine gets the card too", () => {
  expect(cloudAgentLogin(options({ elsewhere: true }, "codex").login)?.agent).toBe("codex");
});

test("an Antigravity chat on Cloud signs in with Gemini's key, the key Cloud's Gemini gateway serves it with", () => {
  expect(harnessLoginAgent("antigravity")).toBe("gemini");
  expect(harnessLoginAgent("gemini")).toBe("gemini");
  expect(harnessLoginAgent("pi")).toBeUndefined();
  expect(cloudAgentLogin(options({ machineID: "vm-1", elsewhere: true }, "antigravity").login)?.agent).toBe("gemini");
});

test("a Cloud chat keeps its card", () => {
  const { login } = options({ machineID: "vm-1", elsewhere: true });
  expect(cloudAgentLogin(login)?.agent).toBe("claude");
  expect(localApiKeyLogin(login)).toBeUndefined();
});

test("a chat on this Mac keeps Use an API key beside Sign in again, and no machine card", () => {
  const { login } = options({ elsewhere: false });
  expect(cloudAgentLogin(login)).toBeUndefined();
  expect(localApiKeyLogin(login)?.agent).toBe("claude");
});

test("the sign-in card follows the machine the chat runs on, not only the acpmux the page talks to", () => {
  const peerChat = { peer: "studio", host: "studio" };
  const kinds = { studio: "ssh" as const };
  // A peer chat: the page's acpmux forwards the login, and the peer must run it too.
  expect(agentLoginSupported(true, peerChat, kinds, {}, { studio: true })).toBe(true);
  expect(agentLoginSupported(true, peerChat, kinds, {}, { studio: false })).toBe(false);
  // The page's acpmux cannot forward what it does not serve, whatever the peer lists.
  expect(agentLoginSupported(false, peerChat, kinds, {}, { studio: true })).toBe(false);
  // An acpmux too old to report the peer's answer keeps its own, as before.
  expect(agentLoginSupported(true, peerChat, kinds, {}, {})).toBe(true);
  // A chat on this Mac, or on the machine the app's wire reaches, runs on the page's acpmux.
  expect(agentLoginSupported(true, { machine: "box" }, {}, {}, { studio: false })).toBe(true);
  expect(agentLoginSupported(true, { machine: "box" }, {}, { origin: "remote" }, { studio: false })).toBe(true);
  // A Cloud peer is a peer too.
  const cloudChat = { peer: "vm-1", hostKind: "cloud" as const };
  expect(agentLoginSupported(true, cloudChat, { "vm-1": "cloud" }, {}, { "vm-1": false })).toBe(false);
});

test("a connected peer's agentLogin is read; a row without one, or a peer not connected, is left out", () => {
  // acpmux forgets a peer's features when its link ends: a peer still handshaking at launch reads
  // false, and recording that would hide its card after it connects.
  expect(
    peerAgentLoginFromStatus({
      peers: [
        { name: "a", connected: true, agentLogin: true },
        { name: "b", connected: true, agentLogin: false },
        { name: "c", connected: true },
        { name: "d", connected: false, agentLogin: false },
      ],
    }),
  ).toEqual({ a: true, b: false });
});

/// hq#11225: a new Cloud chat whose start was refused because its agent is not signed in has no
/// session. Where its machine signs the agent in anyway (`agent_login_machine`), the failed start's
/// card runs each step there with no chat named, and resends nothing (Retry starts the chat).
test("a new chat with no session signs its agent in on its machine where the machine can", async () => {
  const calls: Call[] = [];
  const client = {
    selectedSession: undefined,
    agentLoginStart: (agent: string, sessionId: string | undefined) => {
      calls.push(["start", agent, sessionId]);
      return Promise.resolve({ loginId: "login-1", url: "https://cursor.com/loginDeepControl", needsCode: false });
    },
    agentLoginFinish: (loginId: string, sessionId: string | undefined) => {
      calls.push(["finish", loginId, sessionId]);
      return Promise.resolve({ signedIn: true });
    },
    agentLoginApiKey: () => Promise.resolve({ saved: true }),
    agentLoginCancel: (loginId: string, sessionId: string | undefined) => {
      calls.push(["cancel", loginId, sessionId]);
      return Promise.resolve(undefined);
    },
    resendPrompt: () => {
      calls.push(["resend"]);
      return Promise.resolve({ input: [], attachments: [] });
    },
    send: () => Promise.resolve(undefined),
  };
  const login = {
    connected: true,
    machineID: "vm-1",
    elsewhere: true,
    sessionId: undefined,
    harness: "cursor",
    supported: true,
    gesture: () => Promise.resolve(undefined),
    openURL: () => undefined,
    isCurrent: () => false,
    currentClient: () => client as never,
  };
  // An older machine (no `agent_login_machine`): no card, so SwitchNotice says to sign in there.
  expect(cloudAgentLogin(login)).toBeUndefined();
  expect(cloudAgentLogin({ ...login, machineLogin: false })).toBeUndefined();
  const signIn = cloudAgentLogin({ ...login, machineLogin: true });
  expect(signIn?.agent).toBe("cursor");
  const started = await signIn!.start();
  expect(started.loginId).toBe("login-1");
  expect(await signIn!.finish("login-1")).toBe(true);
  signIn!.cancel("login-1");
  await signIn!.resend("row-1", "hi", { promptId: "p", ticket: "t" });
  expect(calls).toEqual([
    ["start", "cursor", undefined],
    ["finish", "login-1", undefined],
    ["cancel", "login-1", undefined],
  ]);
});

test("a chat with a session keeps naming it, whether or not its machine signs in without one", async () => {
  const { calls, login } = options({ machineID: "vm-1", elsewhere: true }, "claude");
  await cloudAgentLogin({ ...login, machineLogin: true })!.start();
  expect(calls).toEqual([["start", "claude", "chat-1"]]);
});

test("a chat on this Mac gets the in-place card for its built-in agent; a route keeps its own Log In", () => {
  // Logins done right: the built-in Claude Code and Codex sign in in the card; a route (`claude-sr`,
  // `claude-cr`) signs in its own way, so it gets no card that would sign the built-in Claude in.
  expect(localAgentLogin(options({}, "claude").login)?.agent).toBe("claude");
  expect(localAgentLogin(options({}, "codex").login)?.agent).toBe("codex");
  for (const route of ["claude-sr", "claude-cr"]) expect(localAgentLogin(options({}, route).login)).toBeUndefined();
  expect(localAgentLogin(options({ elsewhere: true }, "claude").login)).toBeUndefined();
  expect(localAgentLogin(options({ machineID: "m-1" }, "claude").login)).toBeUndefined();
});

// Sign in again (the agent's own login in a terminal on the chat's machine) stays where it was (a
// chat off Cloud) and now also reaches an older Cloud machine, whose acpmux signs nothing in from the
// card. A current machine keeps its card, and a team machine takes no personal login.
test("Sign in again runs the agent's login in a terminal on an older Cloud machine, not a current or team one", () => {
  const base = {
    connected: true,
    loginCommand: "claude /login",
    card: undefined,
    onCloud: true,
    machineSignsIn: false,
    teamMachine: false,
  };
  expect(terminalSignIn(base)).toEqual({ runs: true, onCloud: true });
  expect(terminalSignIn({ ...base, machineSignsIn: true })).toEqual({ runs: false, onCloud: false });
  expect(terminalSignIn({ ...base, teamMachine: true })).toEqual({ runs: false, onCloud: false });
  expect(terminalSignIn({ ...base, loginCommand: undefined })).toEqual({ runs: false, onCloud: false });
  expect(terminalSignIn({ ...base, connected: false })).toEqual({ runs: false, onCloud: false });
  // Off Cloud: as before, whatever the machine signs in.
  expect(terminalSignIn({ ...base, onCloud: false })).toEqual({ runs: true, onCloud: false });
  expect(terminalSignIn({ ...base, onCloud: false, machineSignsIn: true })).toEqual({ runs: true, onCloud: false });
});

// Codex's `codex login` waits for its browser's redirect to localhost:1455 on the machine, which the
// Mac's browser cannot reach: an older Cloud machine's Codex chat keeps the card as before (Switch
// model), while Claude Code's pasted-code login and any device-code login are offered. Off Cloud,
// every login is offered as before.
test("an older Cloud machine offers Sign in again only for a login that finishes from the Mac's browser", () => {
  const older = { connected: true, card: undefined, onCloud: true, machineSignsIn: false, teamMachine: false };
  for (const command of ["claude /login", "claude auth login", "CLAUDE_CONFIG_DIR=~/.claude-work claude /login"]) {
    expect(signsInRemotely(command), command).toBe(true);
    expect(terminalSignIn({ ...older, loginCommand: command }), command).toEqual({ runs: true, onCloud: true });
  }
  expect(signsInRemotely("codex login --device-auth")).toBe(true);
  for (const command of [
    "codex login",
    "CODEX_HOME=/home/me/.codex-work codex login",
    "opencode auth login",
    "gemini",
    "",
  ]) {
    expect(signsInRemotely(command), command).toBe(false);
    expect(terminalSignIn({ ...older, loginCommand: command }), command).toEqual({ runs: false, onCloud: false });
    expect(terminalSignIn({ ...older, onCloud: false, loginCommand: command }), command).toEqual({
      runs: true,
      onCloud: false,
    });
  }
});

test("a login's end tells the host its pages and hosts once, so the tab it opened closes (finish, refusal, Cancel)", async () => {
  // Logins done right (Leo: "this is simply logins, done righr. end of story."): the sign-in page's
  // tab goes once the login ended; the host decides which tab (AgentPaneSignInTabs.swift).
  const hosts = ["claude.com", "claude.ai"];
  const ended: [string[], string[]][] = [];
  let finish: () => Promise<unknown> = () => Promise.resolve({ signedIn: true });
  const { login } = options({ machineID: "vm-1", elsewhere: true });
  const client = {
    ...(login.currentClient() as object),
    agentLoginStart: () =>
      Promise.resolve({
        loginId: "login-1",
        url: "https://claude.ai/oauth/authorize",
        needsCode: true,
        pageHosts: hosts,
      }),
    agentLoginFinish: () => finish(),
  };
  const signIn = cloudAgentLogin({
    ...login,
    currentClient: () => client as never,
    signInEnded: (urls, named) => ended.push([urls, named]),
  })!;
  const started = await signIn.start();
  expect(started.pageHosts).toEqual(hosts);
  expect(ended).toEqual([]);
  // Signed in: told once; a second finish or a Cancel of the same login tells nothing more.
  expect(await signIn.finish("login-1", "code")).toBe(true);
  await signIn.finish("login-1").catch(() => undefined);
  signIn.cancel("login-1");
  expect(ended).toEqual([[["https://claude.ai/oauth/authorize"], hosts]]);

  // A refused finish (a wrong code, an expired login) ends the login in acpmux too.
  ended.length = 0;
  finish = () => Promise.reject({ code: -32000, data: { reason: "bad_code" } });
  await signIn.start();
  await expect(signIn.finish("login-1", "nope")).rejects.toBeDefined();
  expect(ended).toEqual([[["https://claude.ai/oauth/authorize"], hosts]]);

  // Cancel (the card's Cancel, its expiry, the card going away) tells it too.
  ended.length = 0;
  await signIn.start();
  signIn.cancel("login-1");
  expect(ended).toEqual([[["https://claude.ai/oauth/authorize"], hosts]]);

  // A login this card never started tells nothing.
  ended.length = 0;
  signIn.cancel("login-other");
  expect(ended).toEqual([]);
});

test("an older acpmux names no pageHosts: the host still closes a tab on the page's own host", async () => {
  const ended: [string[], string[]][] = [];
  const { login } = options({ machineID: "vm-1", elsewhere: true });
  const signIn = cloudAgentLogin({ ...login, signInEnded: (urls, hosts) => ended.push([urls, hosts]) })!;
  const started = await signIn.start();
  expect(started.pageHosts).toBeUndefined();
  signIn.cancel(started.loginId);
  expect(ended).toEqual([[["https://claude.ai/oauth/authorize"], []]]);
});
