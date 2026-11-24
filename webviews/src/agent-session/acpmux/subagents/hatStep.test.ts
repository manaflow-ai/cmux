import { expect, test } from "bun:test";
import { experimentArm } from "../../../experiments/experiment";
import { hatPhase } from "./hatStep";
import { hatStepLook } from "./hatStep.experiment";

test("the hat says the kind of call by default, never the call", () => {
  expect(experimentArm(hatStepLook, { overrides: {}, stored: {} })).toBe("phase");
});

test("each ACP kind reads as one word of a bounded list", () => {
  expect(hatPhase({})).toBe("thinking");
  expect(hatPhase({ action: "Read a.ts", actionKind: "read" })).toBe("reading");
  expect(hatPhase({ action: "Grep x", actionKind: "search" })).toBe("searching");
  expect(hatPhase({ action: "Edit a.ts", actionKind: "edit" })).toBe("editing");
  expect(hatPhase({ action: "rm a", actionKind: "delete" })).toBe("editing");
  expect(hatPhase({ action: "ls -la", actionKind: "execute" })).toBe("running");
  expect(hatPhase({ action: "ls -la", actionShell: true })).toBe("running");
  expect(hatPhase({ action: "WebFetch x", actionKind: "fetch" })).toBe("fetching");
  expect(hatPhase({ action: "Agent", actionKind: "think" })).toBe("delegating");
  expect(hatPhase({ action: "mcp__x__y", actionKind: "other" })).toBe("working");
  expect(hatPhase({ action: "Waiting on the macOS job" })).toBe("working");
});
