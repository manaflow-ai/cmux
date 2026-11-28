// cmux#51731: the agent picked for a Cloud machine (cloudAgentPick.ts) is held for the Cloud send and
// never written as this Mac's remembered pick (lastPick.ts).
import { afterEach, expect, test } from "bun:test";
import { clearCloudAgentPick, cloudAgentPick, holdCloudAgentPick } from "../src/agent-session/acpmux/cloudAgentPick";

afterEach(() => clearCloudAgentPick());

test("a pick is held with its model, a later one replaces it, and an empty harness holds nothing", () => {
  expect(cloudAgentPick()).toBeUndefined();
  holdCloudAgentPick({ harness: "codex", model: "gpt-6" });
  expect(cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6" });
  holdCloudAgentPick({ harness: "pi" });
  expect(cloudAgentPick()).toEqual({ harness: "pi" });
  holdCloudAgentPick({ harness: "" });
  expect(cloudAgentPick()).toEqual({ harness: "pi" });
});

// cmux#59716: a page another tab adopts drops the Cloud pick an earlier tab made there, so a Codex chat
// never starts on the Claude a reused page still held. A pick handed to this tab by its own handshake
// stays through the first adoption (the host can replay one right after that handshake).
test("an adoption drops an earlier tab's pick, and keeps a handed one once", async () => {
  const { dropCloudAgentPickForAdoption } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "claude", model: "claude-opus-5-5", effort: "high" });
  dropCloudAgentPickForAdoption();
  expect(cloudAgentPick()).toBeUndefined();
  holdCloudAgentPick({ harness: "codex", model: "gpt-6", handed: true });
  dropCloudAgentPickForAdoption();
  expect(cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6" });
  dropCloudAgentPickForAdoption();
  expect(cloudAgentPick()).toBeUndefined();
});

test("a pick the person makes replaces a handed one, which then no longer survives an adoption", async () => {
  const { dropCloudAgentPickForAdoption } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "codex", handed: true });
  holdCloudAgentPick({ harness: "claude", model: "claude-opus-5-5" });
  expect(cloudAgentPick()).toEqual({ harness: "claude", model: "claude-opus-5-5" });
  dropCloudAgentPickForAdoption();
  expect(cloudAgentPick()).toBeUndefined();
});
