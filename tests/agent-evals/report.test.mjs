import { describe, expect, test } from "bun:test";
import { renderResults, summarize } from "./report.mjs";

const row = (over) => ({
  agent: "claude", surface: "cli", task: "terminal-right", pass: true, score: 1, wall_ms: 1000, calls: 4, ...over,
});

describe("summarize", () => {
  test("groups by agent and surface with pass rate, mean score and top categories", () => {
    const rows = [
      row({}),
      row({ task: "reuse-right", pass: false, score: 0.5, category: "extra_split", calls: 8 }),
      row({ task: "group-tabs", pass: false, score: 0, category: "extra_split", calls: 2 }),
      row({ agent: "codex", pass: false, score: 0.25, category: "focus_stolen" }),
      row({ agent: "opencode", pass: false, score: 0, category: "no_login" }),
    ];
    const s = summarize(rows);
    const claude = s.find((x) => x.agent === "claude");
    expect(claude.n).toBe(3);
    expect(claude.passed).toBe(1);
    expect(claude.mean_score).toBeCloseTo(0.5);
    expect(claude.median_calls).toBe(4);
    expect(claude.top_failures).toEqual([["extra_split", 2]]);
    // An agent with no login is reported, not scored.
    const opencode = s.find((x) => x.agent === "opencode");
    expect(opencode.skipped).toBe("no_login");
    expect(opencode.n).toBe(0);
  });
});

describe("renderResults", () => {
  test("prints a summary table and a per-task matrix", () => {
    const md = renderResults({ run: "r1", date: "2026-10-19", rows: [row({}), row({ agent: "codex", pass: false, score: 0, category: "wrong_place" })] });
    expect(md).toContain("| claude | cli | 1/1 |");
    expect(md).toContain("| codex | cli | 0/1 |");
    expect(md).toContain("wrong_place");
    expect(md).toMatch(/\| terminal-right \| .*pass.*\| .*wrong_place.* \|/);
  });
});
