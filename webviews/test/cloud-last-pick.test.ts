// Cloud's own last pick (cloudLastPick.ts), apart from This Mac's (lastPick.ts). Austin, 2026-11-27:
// "Cloud + autocloud have their own bucket of models and this mac is just your local setup ... We should
// store a state for the local models and a different state for the cloud+autocloud".
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

const mod = () => import("../src/agent-session/acpmux/cloudLastPick");
const sent: Record<string, unknown>[] = [];
const post = async (_method: string, params: Record<string, unknown>) => void sent.push(params);

afterEach(async () => {
  (await mod()).clearCloudLastPick();
  (await import("../src/agent-session/acpmux/cloudAgentPick")).clearCloudAgentPick();
  globalThis.localStorage?.clear();
  sent.length = 0;
});

test("a Cloud pick is Cloud's last pick and the app is told it is Cloud's", async () => {
  const { cloudLastPick, rememberCloudPick } = await mod();
  expect(cloudLastPick()).toBeUndefined();
  rememberCloudPick({ harness: "codex", model: "gpt-6.1" }, post);
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
  expect(sent).toEqual([{ agent: "codex", model: "gpt-6.1", place: "cloud" }]);
});

test("a pick naming no model keeps the model last picked on the same agent, not another agent's", async () => {
  const { cloudLastPick, rememberCloudPick } = await mod();
  rememberCloudPick({ harness: "codex", model: "gpt-6.1" }, post);
  rememberCloudPick({ harness: "codex" }, post);
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
  rememberCloudPick({ harness: "claude" }, post);
  expect(cloudLastPick()).toEqual({ harness: "claude" });
});

test("a Cloud pick never changes This Mac's last pick, and a This Mac pick never changes Cloud's", async () => {
  const { cloudLastPick, rememberCloudPick } = await mod();
  const { lastPick, rememberPick } = await import("../src/agent-session/acpmux/lastPick");
  rememberPick({ harness: "claude", model: "opus-5.5" }, "/p", post);
  rememberCloudPick({ harness: "codex", model: "gpt-6.1" }, post);
  expect(lastPick("/p")).toEqual({ harness: "claude", model: "opus-5.5" });
  rememberPick({ harness: "pi", model: "m" }, "/p", post);
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
});

test("holding a Cloud agent pick remembers it as Cloud's", async () => {
  const { cloudLastPick } = await mod();
  const { holdCloudAgentPick } = await import("../src/agent-session/acpmux/cloudAgentPick");
  holdCloudAgentPick({ harness: "codex", model: "gpt-6.1" });
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
});

test("the app's copy seeds a page until the page picks; a bad copy seeds nothing", async () => {
  const { cloudLastPick, rememberCloudPick, seedCloudLastPick } = await mod();
  seedCloudLastPick({ harness: "", model: "x" });
  seedCloudLastPick(null);
  expect(cloudLastPick()).toBeUndefined();
  seedCloudLastPick({ harness: "codex", model: "gpt-6.1" });
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
  rememberCloudPick({ harness: "claude", model: "opus-5.5" }, post);
  seedCloudLastPick({ harness: "codex", model: "gpt-6.1" });
  expect(cloudLastPick()).toEqual({ harness: "claude", model: "opus-5.5" });
});

test("the New Tab context's lastPicks.cloud seeds Cloud's last pick", async () => {
  const { cloudLastPick } = await mod();
  const { newTabHost } = await import("../src/agent-session/acpmux/newTabModel");
  newTabHost({
    newTab: {
      lastPicks: {
        global: { harness: "claude", model: "default" },
        folders: [],
        cloud: { harness: "codex", model: "gpt-6.1" },
      },
    },
  });
  expect(cloudLastPick()).toEqual({ harness: "codex", model: "gpt-6.1" });
});
