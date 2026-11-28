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

// Leo 2026-11-27: "i think the new chat thing is maybe bc it's trying to "inherit" agent chat but it
// should purely just be new tab". A pick in a chat saves acpmux's start model (`start`, source
// saved); New Tab names its own (`start.newTab`), never the chat's.
test("New Tab's model is its own start, not the one a chat's pick saved", () => {
  const listing = {
    harnesses: {
      codex: {
        kind: "acp",
        models: [{ id: "gpt-6.2-sol" }, { id: "gpt-6-astra" }],
        start: {
          model: "gpt-6-astra",
          modelSource: "saved",
          newTab: { model: "gpt-6.2-sol", modelSource: "catalog" },
        },
      },
    },
    defaultHarness: "codex",
  };
  const snapshot = { ...emptySnapshot(), catalog: normalizeCatalog(listing) };
  expect(snapshot.catalog[0]?.start?.newTab).toEqual({ model: "gpt-6.2-sol", modelSource: "catalog" });
  const agents = snapshot.catalog.map((entry) => ({ id: entry.id, name: entry.name }));
  const shown = newTabStart(snapshot, agents, undefined, undefined, { harness: "", model: "" }, true);
  expect(shown.snapshot.summary?.model).toBe("gpt-6.2-sol");
});
