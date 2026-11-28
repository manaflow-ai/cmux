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

test("Cloud keeps its own effort with its pick: a model pick keeps the level, another agent drops it", async () => {
  const { holdCloudEffortPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "codex", model: "gpt-6" });
  holdCloudEffortPick("codex", "gpt-6", "high");
  expect(cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6", effort: "high" });
  // Picking another model of the same agent never resets the person's level.
  holdCloudAgentPick({ harness: "codex", model: "gpt-6-mini" });
  expect(cloudAgentPick()).toEqual({ harness: "codex", model: "gpt-6-mini", effort: "high" });
  // Another agent's levels are its own.
  holdCloudAgentPick({ harness: "claude", model: "opus" });
  expect(cloudAgentPick()).toEqual({ harness: "claude", model: "opus" });
});

test("the Cloud pick is kept in its own store, apart from This Mac's remembered pick", async () => {
  const values = new Map<string, string>();
  const prior = globalThis.localStorage;
  (globalThis as { localStorage?: unknown }).localStorage = {
    getItem: (k: string) => values.get(k) ?? null,
    setItem: (k: string, v: string) => void values.set(k, v),
    removeItem: (k: string) => void values.delete(k),
  };
  try {
    holdCloudAgentPick({ harness: "codex", model: "gpt-6", effort: "medium" });
    expect(JSON.parse(values.get("cmux.acpmux.cloudPick") ?? "null")).toEqual({
      harness: "codex",
      model: "gpt-6",
      effort: "medium",
    });
    expect(values.has("cmux.acpmux.lastPick")).toBe(false);
  } finally {
    (globalThis as { localStorage?: unknown }).localStorage = prior;
  }
});
