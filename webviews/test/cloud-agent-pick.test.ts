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
