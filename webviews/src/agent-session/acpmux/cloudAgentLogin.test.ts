import { expect, test } from "bun:test";
import { cloudAgentLogin, localApiKeyLogin } from "./cloudAgentLogin";

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
