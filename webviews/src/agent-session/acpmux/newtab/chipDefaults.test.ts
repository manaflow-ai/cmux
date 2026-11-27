import { expect, test } from "bun:test";
import { normalizeCatalog } from "../direct";
import { emptySnapshot } from "../snapshotCache";
import { listedNoDefault, newTabStart } from "./chipDefaults";

// Onboarding probe 2026-11-22: on a fresh Mac acpmux had only the built-in Chief and UniiChat, and a
// new person's first New Tab started on UniiChat, signed out of it. acpmux names no default there
// now (default_harness.rs), and New Tab starts on no agent, so its Add harness setup shows.

const freshMac = { harnesses: { chief: { kind: "acp" }, unii: { kind: "acp" } }, defaultHarness: null };

function start(listing: unknown, lastAgent?: string) {
  const snapshot = { ...emptySnapshot(), catalog: normalizeCatalog(listing) };
  const agents = snapshot.catalog.map((entry) => ({ id: entry.id, name: entry.name }));
  return newTabStart(snapshot, agents, lastAgent, undefined, { harness: "", model: "" }, true).harness;
}

test("a listing that names no default starts New Tab on no agent", () => {
  expect(listedNoDefault(normalizeCatalog(freshMac))).toBe(true);
  expect(start(freshMac)).toBeUndefined();
  // A reply relayed without its null key names no default either.
  expect(start({ harnesses: freshMac.harnesses })).toBeUndefined();
});

test("the agent picked before still starts New Tab when acpmux names no default", () => {
  expect(start(freshMac, "unii")).toBe("unii");
});

test("acpmux's default starts New Tab first", () => {
  const withClaude = {
    harnesses: { ...freshMac.harnesses, claude: { kind: "acp" } },
    defaultHarness: "claude",
  };
  expect(listedNoDefault(normalizeCatalog(withClaude))).toBe(false);
  expect(start(withClaude)).toBe("claude");
});

test("a catalog given as a list keeps its first agent", () => {
  const listed = [{ id: "codex" }, { id: "unii" }];
  expect(listedNoDefault(normalizeCatalog(listed))).toBe(false);
  expect(start(listed)).toBe("codex");
});

test("keeps the remembered model while the chosen harness is unlisted", () => {
  const snapshot = {
    ...emptySnapshot(),
    catalog: normalizeCatalog({ harnesses: { claude: { kind: "acp" } }, defaultHarness: "claude" }),
  };
  const result = newTabStart(
    snapshot,
    [{ id: "claude", name: "Claude" }],
    undefined,
    undefined,
    { harness: "claude", model: "claude-opus" },
    false,
  );
  expect(result.snapshot.summary?.model).toBe("claude-opus");
});

test("drops a remembered model after the chosen harness is absent from a listing", () => {
  const snapshot = {
    ...emptySnapshot(),
    catalog: normalizeCatalog({ harnesses: { codex: { kind: "acp" } }, defaultHarness: "codex" }),
  };
  const result = newTabStart(
    snapshot,
    [{ id: "codex", name: "Codex" }],
    undefined,
    undefined,
    { harness: "claude", model: "claude-opus" },
    true,
  );
  expect(result.snapshot.summary?.model).not.toBe("claude-opus");
});
