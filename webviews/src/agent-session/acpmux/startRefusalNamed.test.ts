// A Cloud start of an agent the machine lacks, or of the cmux router where no router serves it, names
// the cause instead of "<machine> refused to start the agent chat (agent_session.harness_missing)"
// (Leo, 2026-11-15: "so does cloud work? on our thing? just automatically? or switching environments?
// claude and codex alike, through gui? and other harnesses/etc too?"; hq#11225). cmux-tui refuses
// them as `agent_session.harness_missing` (`data.reason` `agent.not_installed`) and
// `agent_session.route_unavailable` (`data.reason` acpmux's `route.*`); acpmux on this Mac says the
// route refusal in `data.reason` only.
import { describe, expect, test } from "bun:test";
import { HarnessSwitch, type SwitchPort } from "./harnessSwitch";
import { startFailureView } from "./startFailure";
import { HARNESS_MISSING, ROUTE_UNAVAILABLE, startRefusalAction } from "./startRefusal";
import type { Translate } from "./i18n";

const t: Translate = ((key: string, params?: Record<string, string>) =>
  `${key}${params ? JSON.stringify(params) : ""}`) as Translate;

const HOST_WORDS = "The cmux router isn't available on devbox-3. Pick another agent, or start the chat again later.";

describe("startFailureView: a missing agent", () => {
  test("names the agent, never the code, with the host's words under Details", () => {
    const view = startFailureView(t, {
      harness: "pi",
      name: "Pi",
      error: "devbox-3 refused to start the agent chat (agent_session.harness_missing).",
      code: HARNESS_MISSING,
    });
    expect(view.sentence).toBe('switch.notInstalled{"agent":"Pi"}');
    expect(view.sentence).not.toContain("agent_session");
    expect(view.detail).toContain("agent_session.harness_missing");
    expect(view.notInstalled).toBe(true);
    expect(view.install).toBeUndefined();
  });
  test("an agent cmux knows how to install offers its installer", () => {
    const view = startFailureView(t, { harness: "gemini", name: "Gemini CLI", code: HARNESS_MISSING });
    expect(view.install).toBeDefined();
    expect(view.detail).toBeUndefined();
  });
  test("an agent with no name is this agent", () => {
    expect(startFailureView(t, { harness: "", name: "", code: HARNESS_MISSING }).sentence).toBe(
      "switch.notInstalledUnnamed",
    );
  });
  test("no way out but Retry (or Install)", () => {
    expect(startRefusalAction(HARNESS_MISSING)).toBeUndefined();
  });
});

describe("startFailureView: an unserved route", () => {
  test("the cmux router is named as the router", () => {
    const view = startFailureView(t, { harness: "cmux", name: "cmux", error: HOST_WORDS, code: ROUTE_UNAVAILABLE });
    expect(view.sentence).toBe("switch.routerUnavailable");
    expect(view.detail).toBe(HOST_WORDS);
    expect(view.install).toBeUndefined();
  });
  test("any other agent by its route", () => {
    expect(startFailureView(t, { harness: "claude", name: "Claude Code", code: ROUTE_UNAVAILABLE }).sentence).toBe(
      'switch.routeUnavailable{"agent":"Claude Code"}',
    );
    expect(startFailureView(t, { harness: "claude", name: " ", code: ROUTE_UNAVAILABLE }).sentence).toBe(
      "switch.routeUnavailableUnnamed",
    );
  });
  test("no way out but Retry", () => {
    expect(startRefusalAction(ROUTE_UNAVAILABLE)).toBeUndefined();
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

async function failedCode(harness: string, error: Error) {
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect(failingPort(error));
  void harnessSwitch.switchTo(harness, "/Users/me/proj");
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const intent = harnessSwitch.view().intent;
  expect(intent?.phase).toBe("failed");
  return intent!.code;
}

describe("HarnessSwitch", () => {
  test("acpmux's route refusal on this Mac reads as the one route code", async () => {
    for (const reason of ["route.unavailable", "route.not_found", "route.invalid"]) {
      const error = Object.assign(new Error("the local CodeRouter is not running"), { code: -32000, reason });
      expect(await failedCode("cmux", error)).toBe(ROUTE_UNAVAILABLE);
    }
  });
  test("acpmux's missing-agent answer reads as the missing-agent code", async () => {
    const error = Object.assign(new Error("pi is not installed"), { code: -32000, reason: "agent.not_installed" });
    expect(await failedCode("pi", error)).toBe(HARNESS_MISSING);
  });
  test("cmux-tui's coded refusals keep their codes", async () => {
    const route = Object.assign(new Error(HOST_WORDS), { code: ROUTE_UNAVAILABLE, reason: "route.unavailable" });
    expect(await failedCode("cmux", route)).toBe(ROUTE_UNAVAILABLE);
    const missing = Object.assign(new Error("x"), { code: HARNESS_MISSING, reason: "agent.not_installed" });
    expect(await failedCode("pi", missing)).toBe(HARNESS_MISSING);
  });
  test("any other refusal keeps no route code", async () => {
    const other = Object.assign(new Error("boom"), { code: -32603, reason: "agent.crashed" });
    expect(await failedCode("claude", other)).toBeUndefined();
  });
});
