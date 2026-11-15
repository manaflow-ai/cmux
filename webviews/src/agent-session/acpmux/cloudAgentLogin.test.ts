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
