// Leo, 2026-11-28 (ask-d4cc021a18): "Keep separate saved state for This Mac versus Cloud + Autocloud."
// "Only explicit human clicks may update saved picks. Backend option lists must not overwrite them."
// "Preserve the selection while a cloud session starts, then apply it when the session is ready."
// "Please record the implementation PR and a before/after state-transition test."
//
// One state machine: This Mac's saved pick (lastPick.ts) and Cloud's (cloudAgentPick.ts held for the
// page, cloudLastPick.ts kept for the next page). Each step is a person's click or a non-human
// source (the app's copy of the picks a New Tab context carries, a page reload); after each, both
// buckets are read. Only a click moves a bucket, and only its own.
import { afterEach, beforeAll, expect, test } from "bun:test";

const store = new Map<string, string>();
beforeAll(() => {
  (globalThis as Record<string, unknown>).localStorage ??= {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
    removeItem: (key: string) => void store.delete(key),
    clear: () => store.clear(),
  };
});

const agentPick = () => import("../src/agent-session/acpmux/cloudAgentPick");
const cloudLast = () => import("../src/agent-session/acpmux/cloudLastPick");
const macLast = () => import("../src/agent-session/acpmux/lastPick");
const post = async () => undefined;

afterEach(async () => {
  (await agentPick()).clearCloudAgentPick();
  (await cloudLast()).clearCloudLastPick();
  globalThis.localStorage?.clear();
});

async function state() {
  const { cloudAgentPick } = await agentPick();
  const { cloudLastPick } = await cloudLast();
  const { lastPick } = await macLast();
  // What the next Cloud send names (PaneComposer.tsx: held, else Cloud's remembered) and This Mac's.
  return { cloud: cloudAgentPick() ?? cloudLastPick(), mac: lastPick("/p") };
}

test("This Mac's and Cloud's saved picks move only on a click, each in its own bucket", async () => {
  const { holdCloudAgentPick, holdCloudEffortPick } = await agentPick();
  const { rememberPick } = await macLast();

  // 1. Click on This Mac: Opus. Only This Mac's moves.
  rememberPick({ harness: "claude", model: "opus-5.5" }, "/p", post);
  expect(await state()).toEqual({ cloud: undefined, mac: { harness: "claude", model: "opus-5.5" } });

  // 2. Click on Cloud: Codex gpt-6. Only Cloud's moves.
  holdCloudAgentPick({ harness: "codex", model: "gpt-6" });
  expect(await state()).toEqual({
    cloud: { harness: "codex", model: "gpt-6" },
    mac: { harness: "claude", model: "opus-5.5" },
  });

  // 3. Click Cloud's level High. The agent and model stay; no chat starts on this Mac, so This Mac's stays.
  holdCloudEffortPick("codex", "gpt-6", "high");
  expect(await state()).toEqual({
    cloud: { harness: "codex", model: "gpt-6", effort: "high" },
    mac: { harness: "claude", model: "opus-5.5" },
  });

  // 4. Click another Cloud model of the same agent: the level the person picked stays.
  holdCloudAgentPick({ harness: "codex", model: "gpt-6-mini" });
  expect((await state()).cloud).toEqual({ harness: "codex", model: "gpt-6-mini", effort: "high" });
});

test("the app's copy of the picks (a backend list) never overwrites a pick the person made", async () => {
  const { holdCloudAgentPick } = await agentPick();
  const { seedCloudLastPick } = await cloudLast();
  const { rememberPick, seedLastPicks } = await macLast();
  rememberPick({ harness: "claude", model: "opus-5.5" }, "/p", post);
  holdCloudAgentPick({ harness: "codex", model: "gpt-6", effort: "high" });
  const before = await state();

  // An older New Tab context arrives naming other picks for both places.
  seedLastPicks({ global: { harness: "pi", model: "m" }, folders: [{ folder: "/p", harness: "pi", model: "m" }] });
  seedCloudLastPick({ harness: "claude", model: "sonnet" });

  expect(await state()).toEqual(before);
});

test("before any click the app's copy seeds a fresh page, and a level picked later keeps its model", async () => {
  const { holdCloudEffortPick } = await agentPick();
  const { seedCloudLastPick } = await cloudLast();
  seedCloudLastPick({ harness: "codex", model: "gpt-6" });
  expect((await state()).cloud).toEqual({ harness: "codex", model: "gpt-6" });
  // A level clicked with no model named (the chip had none yet) keeps the remembered model.
  holdCloudEffortPick("codex", undefined, "low");
  expect((await state()).cloud).toEqual({ harness: "codex", model: "gpt-6", effort: "low" });
});

test("a pick made while the page waits survives a reload: the next Cloud page starts on it, level included", async () => {
  const { holdCloudAgentPick, clearCloudAgentPick, cloudAgentPick } = await agentPick();
  holdCloudAgentPick({ harness: "codex", model: "gpt-6", effort: "high" });
  // The page goes (a Cloud start opens its chat and closes this page): the page's hold is gone.
  clearCloudAgentPick();
  expect(cloudAgentPick()).toBeUndefined();
  // The next Cloud page reads Cloud's remembered pick, never This Mac's or a default.
  expect((await state()).cloud).toEqual({ harness: "codex", model: "gpt-6", effort: "high" });
});

test("another agent's Cloud pick starts without the previous agent's level", async () => {
  const { holdCloudAgentPick } = await agentPick();
  holdCloudAgentPick({ harness: "codex", model: "gpt-6", effort: "xhigh" });
  holdCloudAgentPick({ harness: "claude", model: "opus-5.5" });
  expect((await state()).cloud).toEqual({ harness: "claude", model: "opus-5.5" });
});
