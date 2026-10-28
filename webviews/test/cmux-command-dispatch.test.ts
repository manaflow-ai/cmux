import { expect, test } from "bun:test";
import { composerCommand, cmuxCommandRefusal, CMUX_COMMANDS } from "../src/agent-session/acpmux/cmuxCommands";

const state = {
  summary: true,
  forkable: true,
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
  for (const text of ["/import", "/fork", "/status", "/continue", "/continue Codex", "/btw question"])
    expect(refusal(text)).toBeUndefined();
});

test("Claude terminal-only commands retain their harness and attachment boundary", () => {
  expect(composerCommand("/login", "claude")?.kind).toBe("cliOnly");
  expect(composerCommand("/login", "codex")).toBeUndefined();
  expect(composerCommand("/login", "claude", 1)).toBeUndefined();
});
