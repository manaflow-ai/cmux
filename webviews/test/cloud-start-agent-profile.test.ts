// A Cloud machine carries Claude Code, Codex, OpenCode and pi (web/services/vms/images/agents.ts), never
// this Mac's own harness profiles. A composer on a profile that routes Claude Code or Codex its own way
// (claude-sr2, a ~/.config/cmux/harnesses file) sent that id to the machine, which refused the start as
// `agent_session.harness_missing` ("Claude (SR2) isn't installed on lease-…", cmux#51731).
import { expect, test } from "bun:test";

import { cloudSendAgent } from "../src/agent-session/acpmux/cloudModePick";
import { cloudStartAgent } from "../src/agent-session/acpmux/harnessModes";

test("a Mac-only Claude Code or Codex profile starts its base agent on the Cloud machine", () => {
  for (const [family, harness, runs] of [
    ["claude-sr2", "claude-sr2", "claude"],
    ["claude", "claude-sr2", "claude"],
    [undefined, "claude-cr", "claude"],
    ["codex", "codex-acp", "codex"],
    ["codex-cr", "codex-cr", "codex"],
  ] as const) {
    expect(cloudStartAgent(family, harness)).toEqual({ family: runs, harness: runs, named: true });
    // The model the composer shows still goes: the base agent runs the same model.
    expect(cloudSendAgent(family, harness, "claude-opus-5-5")).toEqual({ harness: runs, model: "claude-opus-5-5" });
  }
});

test("an agent the machine carries is named as is, and UniiChat still leaves the machine's default", () => {
  for (const agent of ["claude", "codex", "opencode", "pi"])
    expect(cloudStartAgent(agent, agent)).toEqual({ family: agent, harness: agent, named: true });
  expect(cloudStartAgent("unii", "unii")).toEqual({ family: "claude", harness: "claude", named: false });
  expect(cloudSendAgent("unii", "unii", "m")).toEqual({});
});

// cmux#51731: an agent the machine does not carry (a Mac-only harness) is never sent to it; the
// machine starts its default instead of refusing the start as `agent_session.harness_missing`.
test("an agent the Cloud machine does not carry starts the machine's default, unnamed", () => {
  for (const agent of ["gemini", "amp", "my-local-tool"])
    expect(cloudStartAgent(agent, agent)).toEqual({ family: "claude", harness: "claude", named: false });
  expect(cloudSendAgent("gemini", "gemini", "gemini-3-pro")).toEqual({});
});

// cmux#51731: with Cloud picked the model picker lists the agents a Cloud machine carries, never this
// Mac's own profiles or a folder's, each pickable whatever this Mac has installed; its last row opens
// Settings > Cloud.
test("the Cloud picker lists the machine's agents only, and its set-up row opens Settings > Cloud", async () => {
  const { cloudPickerEntries, pickerOnCloud, cloudSettingsLink } = await import(
    "../src/agent-session/acpmux/cloudPickerEntries"
  );
  const entry = (id: string, extra: Record<string, unknown> = {}) => ({ id, name: id, models: [], ...extra });
  const shown = cloudPickerEntries([
    entry("claude"),
    entry("claude-sr2", { family: "claude" }),
    entry("codex", { notInstalled: true, pickable: false }),
    entry("gemini"),
    entry("opencode", { unavailable: "not signed in" }),
    entry("pi"),
    entry("claude", { folder: { folder: "/src/a", state: "enabled" } }),
  ] as never);
  expect(shown.map((each) => each.id)).toEqual(["claude", "codex", "opencode", "pi"]);
  for (const each of shown) {
    expect(each.pickable).toBe(true);
    expect("notInstalled" in each || "unavailable" in each).toBe(false);
  }
  const snapshot = (extra: Record<string, unknown>) => ({ rows: [], catalog: [], ...extra }) as never;
  expect(pickerOnCloud(snapshot({ startsOnCloud: true }))).toBe(true);
  expect(pickerOnCloud(snapshot({ summary: { hostKind: "cloud" } }))).toBe(true);
  expect(pickerOnCloud(snapshot({ origin: "remote", ownerCloud: true }))).toBe(true);
  expect(pickerOnCloud(snapshot({ origin: "remote" }))).toBe(false);
  expect(pickerOnCloud(snapshot({ summary: { hostKind: "local" } }))).toBe(false);
  expect(cloudSettingsLink("cmux-dev")).toBe("cmux-dev://settings/cloud");
  expect(cloudSettingsLink("")).toBeUndefined();
});
