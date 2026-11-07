// A hidden chat's page let go (agents.hiddenChats.discard) keeps its open folds and says whether its
// composer holds a draft, through the wake state the host keeps (AgentPaneWakeState.swift).
import { expect, test } from "bun:test";
import { composerHoldsDraft, readWakeFolds, WAKE_FOLD_LIMIT, wakeFolds, type PaneFolds } from "./wakeFolds";

/// The host keeps the answer as JSON (Codable) and hands it back with the next page's handshake.
const throughHost = (value: unknown): unknown => JSON.parse(JSON.stringify({ folds: value })).folds;

test("open folds come back on the page built again for the same chat", () => {
  const left: PaneFolds = {
    expanded: new Set(["worked-r1", "tool-r7", "subagents-2"]),
    opened: new Set(["subagents-2"]),
    viewToggles: new Map([
      ["thinking", new Set(["worked-r1"])],
      ["verbose", new Set<string>()],
    ]),
  };
  const back = readWakeFolds(throughHost(wakeFolds("s-1", left)), "s-1");
  expect(back).toBeDefined();
  expect([...(back?.expanded ?? [])]).toEqual(["worked-r1", "tool-r7", "subagents-2"]);
  expect([...(back?.opened ?? [])]).toEqual(["subagents-2"]);
  expect([...(back?.viewToggles.get("thinking") ?? [])]).toEqual(["worked-r1"]);
  expect(back?.viewToggles.has("verbose")).toBe(false);
});

test("another chat's folds, nothing open and malformed values give nothing back", () => {
  const folds = wakeFolds("s-1", { expanded: new Set(["tool-r1"]), opened: new Set(), viewToggles: new Map() });
  expect(readWakeFolds(throughHost(folds), "s-2")).toBeUndefined();
  expect(wakeFolds("s-1", { expanded: new Set(), opened: new Set(), viewToggles: new Map() })).toBeUndefined();
  expect(
    wakeFolds(undefined, { expanded: new Set(["tool-r1"]), opened: new Set(), viewToggles: new Map() }),
  ).toBeUndefined();
  expect(readWakeFolds("folds", "s-1")).toBeUndefined();
  const odd = readWakeFolds(
    { session: "s-1", expanded: ["tool-r1", 4, null], viewToggles: { sideways: ["x"] } },
    "s-1",
  );
  expect([...(odd?.expanded ?? [])]).toEqual(["tool-r1"]);
  expect(odd?.viewToggles.size).toBe(0);
});

test("a long chat keeps only its newest folds", () => {
  const many = Array.from({ length: WAKE_FOLD_LIMIT + 50 }, (_, index) => `tool-r${index}`);
  const folds = wakeFolds("s-1", { expanded: new Set(many), opened: new Set(), viewToggles: new Map() });
  expect(folds?.expanded?.length).toBe(WAKE_FOLD_LIMIT);
  expect(folds?.expanded?.[0]).toBe("tool-r50");
  expect(folds?.expanded?.at(-1)).toBe(`tool-r${WAKE_FOLD_LIMIT + 49}`);
  // A longer list from the host is bounded on the way back too.
  expect(readWakeFolds({ session: "s-1", expanded: many }, "s-1")?.expanded.size).toBe(WAKE_FOLD_LIMIT);
});

test("a composer with typed text or chips holds a draft; blank text does not", () => {
  expect(composerHoldsDraft("fix the build", [])).toBe(true);
  expect(composerHoldsDraft("", [{ id: "chip" }])).toBe(true);
  expect(composerHoldsDraft("  \n", [])).toBe(false);
  expect(composerHoldsDraft("", [])).toBe(false);
});
