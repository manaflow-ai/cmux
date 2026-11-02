import { expect, test } from "bun:test";
import {
  composerCommand,
  cmuxCommandRefusal,
  CMUX_COMMANDS,
  harnessTakesToo,
} from "../src/agent-session/acpmux/cmuxCommands";

const state = {
  summary: true,
  forkable: true,
  sideAvailable: true,
  canContinue: true,
  sideSessions: true,
  session: true,
  isSideSession: false,
  targets: [{ id: "codex", name: "Codex" }],
};
const refusal = (text: string, overrides: Partial<typeof state> = {}) => {
  const command = composerCommand(text, "claude");
  expect(command?.kind).toBe("cmux");
  if (command?.kind !== "cmux") throw new Error("Missing owned command");
  return cmuxCommandRefusal(command.command, command.args, { ...state, ...overrides });
};

test("owned commands are recognized independently of menu availability, even with attachments", () => {
  for (const command of CMUX_COMMANDS) expect(composerCommand(`/${command.name}`, "claude", 1)?.kind).toBe("cmux");
  expect(composerCommand("/unknown", "claude")).toBeUndefined();
  expect(composerCommand("/forked", "claude")).toBeUndefined();
});

test("disabled and malformed commands return reasons rather than dispatching", () => {
  expect(refusal("/side", { forkable: false })).toBe("composer.cmuxSideUnavailable");
  expect(refusal("/side", { sideAvailable: false })).toBe("composer.cmuxSideUnavailable");
  expect(refusal("/side question")).toBe("composer.cmuxSideUnavailable");
  expect(refusal("/fork", { forkable: false })).toBe("composer.cmuxForkBusy");
  expect(refusal("/continue codex", { canContinue: false })).toBe("composer.cmuxContinueBusy");
  expect(refusal("/status", { summary: false })).toBe("composer.cmuxStatusUnavailable");
  expect(refusal("/btw question", { sideSessions: false })).toBe("composer.cmuxBtwDisabled");
  expect(refusal("/fork question")).toBe("composer.cmuxForkArgs");
  expect(refusal("/btw")).toBe("composer.cmuxBtwQuestion");
  expect(refusal("/continue nope")).toBe("composer.cmuxContinueUnknown");
  expect(refusal("/btw question", { session: false })).toBe("composer.cmuxUnavailable");
});

test("valid commands retain their actions", () => {
  for (const text of ["/import", "/side", "/fork", "/status", "/continue", "/continue Codex", "/btw question"])
    expect(refusal(text)).toBeUndefined();
});

test("Claude terminal-only commands retain their harness and attachment boundary", () => {
  expect(composerCommand("/logout", "claude")?.kind).toBe("cliOnly");
  expect(composerCommand("/logout", "codex")).toBeUndefined();
  expect(composerCommand("/logout", "claude", 1)).toBeUndefined();
});

test("GUI commands the harness also takes are cmux's, never refused, and sent as typed without a host", () => {
  for (const text of ["/model", "/model opus", "/fast", "/context", "/plan", "/plan explain"]) {
    expect(refusal(text)).toBeUndefined();
    const command = composerCommand(text, "claude");
    if (command?.kind !== "cmux") throw new Error(`Missing owned command for ${text}`);
    expect(harnessTakesToo(command.command)).toBe(true);
  }
  for (const text of ["/import", "/status", "/btw question", "/side", "/fork", "/continue"]) {
    const command = composerCommand(text, "claude");
    if (command?.kind !== "cmux") throw new Error(`Missing owned command for ${text}`);
    expect(harnessTakesToo(command.command)).toBe(false);
  }
  // A bare Claude `/model` opens cmux's picker; it is no longer a terminal-only command.
  expect(composerCommand("/model", "claude")?.kind).toBe("cmux");
  expect(composerCommand("/config", "claude")?.kind).toBe("cliOnly");
});
