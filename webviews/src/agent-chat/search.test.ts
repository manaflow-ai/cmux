import { describe, expect, test } from "bun:test";
import type { ConversationItem } from "./protocol";
import {
  HIGHLIGHT_MAX_MARKS,
  HIGHLIGHT_SCAN_CHARS,
  clampCursor,
  computeMatches,
  highlightSegments,
  initialSearchUIState,
  itemMatchesQuery,
  normalizeSearchQuery,
  reduceSearchUI,
  type SearchUIState,
} from "./search";

function item(id: string, overrides: Partial<ConversationItem> = {}): ConversationItem {
  return {
    id,
    type: "user_message",
    status: "completed",
    ...overrides,
  } as ConversationItem;
}

describe("reduceSearchUI", () => {
  test("open bumps openCount so repeat Cmd+F re-keys (and refocuses) the input", () => {
    let state = initialSearchUIState();
    state = reduceSearchUI(state, { type: "open" });
    state = reduceSearchUI(state, { type: "open" });
    expect(state.open).toBe(true);
    expect(state.openCount).toBe(2);
  });

  test("close clears the query and cursor but keeps filter mode sticky", () => {
    let state: SearchUIState = {
      open: true,
      openCount: 1,
      query: "needle",
      filterMode: true,
      cursor: 3,
    };
    state = reduceSearchUI(state, { type: "close" });
    expect(state).toMatchObject({ open: false, query: "", cursor: 0, filterMode: true });
    expect(reduceSearchUI(state, { type: "close" })).toBe(state);
  });

  test("set-query resets the cursor", () => {
    let state = reduceSearchUI(initialSearchUIState(), { type: "open" });
    state = reduceSearchUI(state, { type: "step", direction: 1, matchCount: 5 });
    state = reduceSearchUI(state, { type: "set-query", query: "x" });
    expect(state.cursor).toBe(0);
  });

  test("step wraps around in both directions and ignores zero matches", () => {
    let state = reduceSearchUI(initialSearchUIState(), { type: "open" });
    state = reduceSearchUI(state, { type: "step", direction: -1, matchCount: 3 });
    expect(state.cursor).toBe(2);
    state = reduceSearchUI(state, { type: "step", direction: 1, matchCount: 3 });
    expect(state.cursor).toBe(0);
    expect(reduceSearchUI(state, { type: "step", direction: 1, matchCount: 0 })).toBe(state);
  });

  test("step clamps a stale cursor before moving (items shrank)", () => {
    const state: SearchUIState = {
      open: true,
      openCount: 1,
      query: "x",
      filterMode: false,
      cursor: 9,
    };
    expect(reduceSearchUI(state, { type: "step", direction: 1, matchCount: 3 }).cursor).toBe(0);
  });

  test("toggle-filter flips filter mode", () => {
    const state = reduceSearchUI(initialSearchUIState(), { type: "toggle-filter" });
    expect(state.filterMode).toBe(true);
  });
});

describe("clampCursor", () => {
  test("clamps into range and zeroes on no matches", () => {
    expect(clampCursor(5, 3)).toBe(2);
    expect(clampCursor(-1, 3)).toBe(0);
    expect(clampCursor(2, 0)).toBe(0);
  });
});

describe("matching", () => {
  test("whitespace-only queries match nothing", () => {
    expect(normalizeSearchQuery("   ")).toBe("");
    expect(computeMatches([item("a", { text: "   " })], "   ")).toEqual([]);
  });

  test("matches across text, title, tool name, output, and input command", () => {
    const lower = normalizeSearchQuery("NeEdLe");
    expect(itemMatchesQuery(item("a", { text: "the Needle here" }), lower)).toBe(true);
    expect(itemMatchesQuery(item("b", { title: "needle title" }), lower)).toBe(true);
    expect(itemMatchesQuery(item("c", { tool_name: "needle-tool" }), lower)).toBe(true);
    expect(
      itemMatchesQuery(item("d", { output: { text: "out needle put" } } as never), lower),
    ).toBe(true);
    expect(itemMatchesQuery(item("e", { input: { command: "grep needle" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("f", { text: "haystack only" }), lower)).toBe(false);
  });

  test("computeMatches returns matching indexes in timeline order", () => {
    const items = [
      item("a", { text: "needle" }),
      item("b", { text: "nope" }),
      item("c", { title: "needle too" }),
    ];
    expect(computeMatches(items, "needle")).toEqual([0, 2]);
  });
});

describe("highlightSegments", () => {
  test("splits into plain and match segments, case-insensitively", () => {
    expect(highlightSegments("a Needle b needle", "needle")).toEqual([
      { text: "a ", match: false },
      { text: "Needle", match: true },
      { text: " b ", match: false },
      { text: "needle", match: true },
    ]);
  });

  test("empty query or text passes through unhighlighted", () => {
    expect(highlightSegments("abc", "")).toEqual([{ text: "abc", match: false }]);
    expect(highlightSegments("", "x")).toEqual([{ text: "", match: false }]);
  });

  test("caps decorated marks and passes the remainder through plain", () => {
    const text = "x".repeat(10) + "hit ".repeat(HIGHLIGHT_MAX_MARKS + 50);
    const segments = highlightSegments(text, "hit");
    const marks = segments.filter((segment) => segment.match);
    expect(marks.length).toBe(HIGHLIGHT_MAX_MARKS);
    expect(segments.map((segment) => segment.text).join("")).toBe(text);
  });

  test("never scans past the highlight window but preserves the full text", () => {
    const text = "a".repeat(HIGHLIGHT_SCAN_CHARS) + "needle";
    const segments = highlightSegments(text, "needle");
    expect(segments.every((segment) => !segment.match)).toBe(true);
    expect(segments.map((segment) => segment.text).join("")).toBe(text);
  });
});

describe("input field coverage and incremental scanning", () => {
  test("matches the visible tool input fields (paths, queries, patch text)", () => {
    const lower = normalizeSearchQuery("target");
    expect(itemMatchesQuery(item("a", { input: { file_path: "/src/target.ts" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("b", { input: { path: "/etc/target" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("c", { input: { notebook_path: "/nb/target.ipynb" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("d", { input: { query: "find the target" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("e", { input: { url: "https://target.dev" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("f", { input: { patch: "*** Update File: src/target.ts" } }), lower)).toBe(true);
    expect(itemMatchesQuery(item("g", { input: { irrelevant: "target" } }), lower)).toBe(false);
  });

  test("computeMatches rescans only changed item objects (identity cache)", () => {
    const stable = item("a", { text: "needle here" });
    const original = item("b", { text: "nothing" });
    let scans: string[] = [];
    const log = (entry: ConversationItem) => scans.push(entry.id);

    expect(computeMatches([stable, original], "needle", log)).toEqual([0]);
    expect(scans).toEqual(["a", "b"]);

    // Streamed update replaces only item b; a is a cache hit.
    scans = [];
    const updated = item("b", { text: "now has needle" });
    expect(computeMatches([stable, updated], "needle", log)).toEqual([0, 1]);
    expect(scans).toEqual(["b"]);

    // Same items, same query: zero scans.
    scans = [];
    expect(computeMatches([stable, updated], "needle", log)).toEqual([0, 1]);
    expect(scans).toEqual([]);

    // A query change re-scans everything once.
    scans = [];
    computeMatches([stable, updated], "other", log);
    expect(scans).toEqual(["a", "b"]);
  });
});
