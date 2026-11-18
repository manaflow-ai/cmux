// A start refused because its agent is not signed in on the machine names the agent and offers
// its sign-in, never the bare "started but its agent didn't (agent_session.refused)" (Leo,
// 2026-11-15: "so does cloud work? on our thing? just automatically? ... claude and codex alike,
// through gui? and other harnesses/etc too?"; hq#11225). cmux-tui refuses such a start with
// `agent_session.sign_in_required` and `data.errorKind`; acpmux on this Mac types the agent's own
// answer with `data.reason` `agent.sign_in_required`.
import { describe, expect, test } from "bun:test";
import { HarnessSwitch, type SwitchPort } from "./harnessSwitch";
import { startFailureView } from "./startFailure";
import { SIGN_IN_REQUIRED, signInRoute, startRefusalAction } from "./startRefusal";
import type { Translate } from "./i18n";

const t: Translate = ((key: string, params?: Record<string, string>) =>
  `${key}${params ? JSON.stringify(params) : ""}`) as Translate;

describe("startRefusalAction", () => {
  test("a start whose agent is not signed in offers Sign in", () => {
    expect(SIGN_IN_REQUIRED).toBe("agent_session.sign_in_required");
    expect(startRefusalAction("agent_session.sign_in_required")).toBe("signIn");
  });
});

describe("signInRoute", () => {
  test("a chat on another machine signs in with the machine's own sign-in card", () => {
    expect(signInRoute({ elsewhere: true, card: true, login: true })).toBe("card");
    expect(signInRoute({ elsewhere: true, card: true, login: false })).toBe("card");
  });
  test("a chat on another machine without the card never runs a login on this Mac", () => {
    expect(signInRoute({ elsewhere: true, card: false, login: true })).toBeUndefined();
  });
  test("a chat on this Mac runs the agent's login in a terminal tab", () => {
    expect(signInRoute({ elsewhere: false, card: false, login: true })).toBe("terminal");
    expect(signInRoute({ elsewhere: false, card: false, login: false })).toBeUndefined();
  });
});

describe("startFailureView", () => {
  const refused = (name: string, extra: { signInExpired?: true; error?: string } = {}) =>
    startFailureView(t, {
      harness: "cursor",
      name,
      error: extra.error ?? "Authentication required",
      code: "agent_session.sign_in_required",
      ...(extra.signInExpired && { signInExpired: true as const }),
    });

  test("names the agent that is not signed in, with the agent's words under Details", () => {
    const view = refused("Cursor");
    expect(view.sentence).toBe('switch.signInRequired{"agent":"Cursor"}');
    expect(view.detail).toBe("Authentication required");
    expect(view.install).toBeUndefined();
  });
  test("an expired sign-in says it expired", () => {
    expect(refused("Grok", { signInExpired: true }).sentence).toBe('switch.signInExpired{"agent":"Grok"}');
  });
  test("an agent with no name is this agent", () => {
    expect(refused("").sentence).toBe("switch.signInRequiredUnnamed");
  });
  test("a refusal with no words still names the cause", () => {
    const view = startFailureView(t, { harness: "gemini", name: "Gemini CLI", code: "agent_session.sign_in_required" });
    expect(view.sentence).toBe('switch.signInRequired{"agent":"Gemini CLI"}');
    expect(view.detail).toBeUndefined();
  });
});

function failingPort(error: Error): SwitchPort {
  return {
    turnRunning: () => false,
    shown: () => undefined,
    create: async () => {
      throw error;
    },
    leave: () => undefined,
    open: async () => undefined,
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  };
}

async function failedIntent(harness: string, error: Error) {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(failingPort(error));
  void harnessSwitch.switchTo(harness, "/Users/me/proj");
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const intent = harnessSwitch.view().intent;
  expect(intent?.phase).toBe("failed");
  return intent!;
}

describe("HarnessSwitch", () => {
  test("acpmux's typed sign-in refusal on this Mac is the sign-in code", async () => {
    // The RPC error direct.ts builds from acpmux's typed `session/new` answer (recovery.rs `start_sign_in`).
    const error = Object.assign(new Error("Authentication required"), {
      code: -32000,
      reason: "agent.sign_in_required",
      errorKind: "auth.signed_out",
      recovery: "cursor is not signed in on this machine.",
      details: { harness: "cursor" },
    });
    const intent = await failedIntent("cursor", error);
    expect(intent.code).toBe("agent_session.sign_in_required");
    expect(intent.signInExpired).toBeUndefined();
    expect(intent.error).toBe("Authentication required");
  });
  test("cmux-tui's refusal for another machine keeps its code and says an expired sign-in", async () => {
    const error = Object.assign(new Error("the agent is not signed in on this machine"), {
      code: "agent_session.sign_in_required",
      reason: "agent.sign_in_required",
      errorKind: "auth.expired",
      harness: "grok",
    });
    const intent = await failedIntent("grok", error);
    expect(intent.code).toBe("agent_session.sign_in_required");
    expect(intent.signInExpired).toBe(true);
  });
});
