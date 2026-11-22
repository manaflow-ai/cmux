import { describe, expect, test } from "bun:test";
import { intervalText, pairedBootstrap, pairedComparison, renderResults, summarize, wilson } from "./report.mjs";

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
    expect(md).toContain("| claude | cli | 1/1 | 21-100% |");
    expect(md).toContain("| codex | cli | 0/1 | 0-79% |");
    expect(md).toContain("wrong_place");
    expect(md).toMatch(/\| terminal-right \| .*pass.*\| .*wrong_place.* \|/);
  });
});

describe("wilson", () => {
  test("matches Newcombe (1998) Table I, method 3, to four places", () => {
    const cases = [
      [81, 263, 0.2553, 0.3662],
      [15, 148, 0.0624, 0.1605],
      [0, 20, 0, 0.1611],
      [1, 29, 0.0061, 0.1718],
      [0, 10, 0, 0.2775],
      [1, 10, 0.0179, 0.4042],
    ];
    for (const [k, n, lo, hi] of cases) {
      const [l, h] = wilson(k, n);
      expect(l).toBeCloseTo(lo, 4);
      expect(h).toBeCloseTo(hi, 4);
    }
    expect(wilson(0, 0)).toEqual([0, 1]);
    expect(intervalText(3, 30)).toBe("3-26%");
  });
});

describe("pairedBootstrap", () => {
  test("identical items have no noise; every item flipping is certain", () => {
    expect(pairedBootstrap([1, 0, 1], [1, 0, 1])).toMatchObject({ diff: 0, lo: 0, hi: 0, verdict: "not distinguishable" });
    expect(pairedBootstrap(Array(10).fill(0), Array(10).fill(1))).toMatchObject({ lo: 1, hi: 1, verdict: "B ahead" });
  });
  test("3 of 30 discordant one way is not a result; 15 of 30 is", () => {
    const zeros = Array(30).fill(0);
    const three = pairedBootstrap(zeros, [1, 1, 1, ...Array(27).fill(0)]);
    expect(three.diff).toBeCloseTo(0.1);
    expect(three.lo).toBe(0);
    expect(three.verdict).toBe("not distinguishable");
    const fifteen = pairedBootstrap(zeros, [...Array(15).fill(1), ...Array(15).fill(0)]);
    expect(fifteen.lo).toBeGreaterThan(0.25);
    expect(fifteen.verdict).toBe("B ahead");
  });
  test("pairs two columns by task, a task's runs as one pass fraction", () => {
    const rows = [
      row({ task: "a" }),
      row({ task: "a", pass: false, score: 0, category: "wrong_place" }),
      row({ task: "b" }),
      row({ surface: "mcp", task: "a" }),
      row({ surface: "mcp", task: "a" }),
      row({ surface: "mcp", task: "b" }),
      row({ surface: "mcp", task: "only-mcp" }),
    ];
    const c = pairedComparison(rows, "claude/cli", "claude/mcp");
    expect(c.n).toBe(2);
    expect(c.diff).toBeCloseTo(0.25);
    expect(c.text).toStartWith("claude/mcp - claude/cli: +25 pts per task");
    expect(renderResults({ run: "r", date: "d", rows, compare: [["claude/cli", "claude/mcp"]] })).toContain("not distinguishable");
  });
});
