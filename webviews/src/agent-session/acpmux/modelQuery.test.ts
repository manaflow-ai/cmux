import { describe, expect, test } from "bun:test";
import { compactContext, matchRank, parseQuery } from "./modelQuery";

const words = (text: string) => parseQuery(text, new Set());

describe("model query ranking", () => {
  // Round 1 brief: a typed name jumps to that exact model, not to whatever contains it first.
  test("an exact name ranks before a prefix, a word start and a plain contains", () => {
    const query = words("sonnet 5.5");
    const exact = matchRank({ id: "claude-sonnet-5-5", name: "Sonnet 5.5" }, "Claude Code", query);
    const prefix = matchRank({ id: "claude-sonnet-5-5-1m", name: "Sonnet 5.5 (1M)" }, "Claude Code", query);
    const word = matchRank({ id: "x", name: "Claude Sonnet 5.5" }, "Claude Code", query);
    const contains = matchRank({ id: "x", name: "Unsonnet 5.5x" }, "Claude Code", query);
    expect(exact).toBeLessThan(prefix);
    expect(prefix).toBeLessThan(word);
    expect(word).toBeLessThan(contains);
  });

  test("a harness-only match ranks after any name match", () => {
    const query = words("claude");
    expect(matchRank({ id: "a", name: "Claude Sonnet" }, "Claude Code", query)).toBeLessThan(
      matchRank({ id: "b", name: "Opus 5.5" }, "Claude Code", query),
    );
  });

  test("context windows read compact", () => {
    expect(compactContext(200_000, "en")).toBe("200K");
    expect(compactContext(1_000_000, "en")).toBe("1M");
    expect(compactContext(undefined, "en")).toBeUndefined();
  });
});
