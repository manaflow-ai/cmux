// Retry's model menu lists each model once, in the composer picker's order (Leo 2026-10-20: Opus
// 5.5, Sonnet 5.5 and Haiku 5.5 each showed twice, under a stale tail of every old release). The
// list is Claude Code's as Leo's screenshot showed it: its aliases named as the releases they run,
// its 1M and plan modes, then every release, the aliases' ones again.
import { describe, expect, test } from "bun:test";
import { retryModelSections } from "../src/agent-session/acpmux/conversation/retryModelSections";
import { topModelsFor } from "../src/agent-session/acpmux/topModels";

const claude = [
  { id: "opus", name: "Opus 5.5", release: "claude-opus-5-5" },
  { id: "claude-fable-5-1[1m]", name: "Fable 5.1 · 1M context" },
  { id: "sonnet", name: "Sonnet 5.5", release: "claude-sonnet-5-5" },
  { id: "haiku", name: "Haiku 5.5", release: "claude-haiku-5-5" },
  { id: "opus[1m]", name: "Opus · 1M context" },
  { id: "opusplan", name: "Opus plan · Sonnet execute" },
  { id: "sonnet[1m]", name: "Sonnet · 1M context" },
  { id: "claude-fable-5-1", name: "Fable 5.1" },
  { id: "claude-fable-5", name: "Fable 5" },
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-opus-5", name: "Opus 5" },
  { id: "claude-opus-4-8", name: "Opus 4.8" },
  { id: "claude-opus-4-7", name: "Opus 4.7" },
  { id: "claude-opus-4-6", name: "Opus 4.6" },
  { id: "claude-opus-4-5", name: "Opus 4.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-sonnet-5", name: "Sonnet 5" },
  { id: "claude-sonnet-4-6", name: "Sonnet 4.6" },
  { id: "claude-sonnet-4-5", name: "Sonnet 4.5" },
  { id: "claude-haiku-5-5", name: "Haiku 5.5" },
  { id: "claude-haiku-4-5", name: "Haiku 4.5" },
  // The same id twice (two catalog layers listing one model).
  { id: "claude-haiku-4-5", name: "Claude Haiku 4.5" },
];
const top = topModelsFor("claude");
const names = (list: readonly { name: string }[]) => list.map((model) => model.name);

describe("Retry's model list", () => {
  test("reported provider identities survive name deduplication and unavailable alternatives", () => {
    const models = [
      { id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol" },
      { id: "azure/gpt-6.1-sol", name: "GPT-6.1 Sol" },
    ];
    for (const current of [undefined, models[1]!.id]) {
      const result = retryModelSections(models, current, "OpenCode", [models[1]!.id]);
      expect(result.latest.map((model) => model.id)).toEqual([current ?? models[0]!.id]);
      expect(result.more).toEqual([]);
    }
    const result = retryModelSections(
      [{ ...models[0]!, unavailable: "not signed in" }, models[1]!],
      undefined,
      "OpenCode",
      [models[1]!.id],
    );
    expect(result.latest.map((model) => model.id)).toEqual([models[1]!.id]);
  });

  for (const current of ["claude-opus-5-5", "opus", "claude-opus-4-8", "opusplan", undefined])
    test(`has no duplicate ids or names (running ${current ?? "nothing"})`, () => {
      const { latest, more } = retryModelSections(claude, current, "Claude Code", top);
      const rows = [...latest, ...more];
      expect(rows.length).toBeGreaterThan(0);
      expect(new Set(rows.map((model) => model.id)).size, "each id once").toBe(rows.length);
      expect(new Set(names(rows)).size, "each name once").toBe(rows.length);
      if (current)
        expect(
          rows.map((model) => model.id),
          "the running model stays reachable, including under More models",
        ).toContain(current);
    });

  test("lists the curated top models first and folds the rest under More models", () => {
    const { latest, more } = retryModelSections(claude, "claude-opus-5-5", "Claude Code", top);
    expect(names(latest)).toEqual(["Opus 5.5", "Sonnet 5.5", "Haiku 5.5", "Fable 5.1"]);
    expect(names(more)).toContain("Fable 5.1 · 1M context");
    expect(names(more)).toContain("Opus 4.8");
    expect(names(more)).toContain("Opus plan · Sonnet execute");
    expect(latest.find((model) => model.name === "Opus 5.5")?.id, "the running row stays the checked one").toBe(
      "claude-opus-5-5",
    );
  });

  test("a running older model stays folded like the composer's older models", () => {
    const { latest, more } = retryModelSections(claude, "claude-opus-4-8", "Claude Code", top);
    expect(names(latest)).not.toContain("Opus 4.8");
    expect(names(more)).toContain("Opus 4.8");
  });

  test("without a curated list each family's newest leads and older releases fold", () => {
    const { latest, more } = retryModelSections(claude, "claude-opus-5-5", "Claude Code");
    expect(names(latest)).toContain("Opus 5.5");
    expect(names(latest)).not.toContain("Opus 4.8");
    expect(names(more)).toContain("Opus 4.8");
  });
});
