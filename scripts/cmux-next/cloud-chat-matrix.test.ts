import { expect, test } from "bun:test";
import { CELLS, judge, table } from "./cloud-chat-matrix";

const cell = (id: string) => CELLS.find((c) => c.id === id)!;
const pass = (step: string, ms = 1000, detail = "") => ({ step, status: "pass" as const, ms, detail });
const fail = (step: string, ms: number, detail: string) => ({ step, status: "fail" as const, ms, detail });

test("a cell passes only when every step did, and reports its timings", () => {
  const steps = [pass("create machine", 3000), pass("reply", 1034, "Stub reply abc."), pass("turn 2 (same session)", 5060), pass("pause", 1965), pass("resume", 3174), pass("turn after resume", 6984)];
  const row = judge(cell("codex-chatgpt-stub"), steps, 0);
  expect(row.verdict).toBe("pass");
  expect(row.ms).toEqual({ "create machine": 3000, reply: 1034, "turn 2 (same session)": 5060, pause: 1965, resume: 3174, "turn after resume": 6984 });
  expect(judge(cell("codex-chatgpt-stub"), [...steps, fail("delete", 10, "gone?")], 1).verdict).toBe("fail");
  // The journey's own summary line is not a step failure.
  expect(judge(cell("codex-chatgpt-stub"), [...steps, fail("prod: 6 passed, 0 failed", 0, "")], 0).verdict).toBe("pass");
});

test("a hung Codex reply is a failure that names the step", () => {
  const row = judge(cell("codex-model-plane"), [pass("start agent (codex)"), fail("reply", 305357, "no reply within 300 s; last: ")], 1);
  expect(row.verdict).toBe("fail");
  expect(row.why).toStartWith("reply: no reply within 300 s");
});

test("a signed-out agent passes only by failing fast with its sign-in error", () => {
  const c = cell("gemini-signed-out");
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 2100, "acp wait exit 1: Authentication required")], 1).verdict).toBe("pass");
  // Not installed is not signed out.
  const missing = judge(c, [fail("start agent (gemini)", 1193, 'unknown harness "gemini"')], 1);
  expect(missing.verdict).toBe("fail");
  expect(missing.why).toContain("unknown harness");
  // A hang is not a refusal, nor is a refusal that took too long.
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 120_000, "no reply within 120 s; last: ")], 1).verdict).toBe("fail");
  expect(judge(c, [pass("start agent (gemini)"), fail("reply", 90_000, "Authentication required")], 1).verdict).toBe("fail");
  // A reply where a refusal belongs is a failure too.
  expect(judge(c, [pass("start agent (gemini)"), pass("reply", 900, "Earth")], 0).verdict).toBe("fail");
});

test("no cell needs an account Leo does not have", () => {
  expect(CELLS.some((c) => c.agent === "cursor" || c.agent === "grok")).toBe(false);
});

test("the table has one row per cell and escapes pipes", () => {
  const rows = [judge(cell("codex-model-plane"), [fail("reply", 1, "a | b")], 1)];
  const md = table(rows);
  expect(md.split("\n")).toHaveLength(3);
  expect(md).toContain("a \\| b");
});

test("OpenCode on Zen runs every turn; signed-out Gemini passes only by refusing fast", () => {
  const steps = [pass("create machine", 5507), pass("reply", 2849, "pong"), pass("turn 2 (same session)", 2862), pass("pause", 1687), pass("resume", 1267), pass("turn after resume", 4118)];
  expect(judge(cell("opencode-zen"), steps, 0).verdict).toBe("pass");
  expect(cell("opencode-zen").args).toContain("--lifecycle");
  for (const id of ["gemini-signed-out"]) {
    const c = cell(id);
    expect(judge(c, [pass(`start agent (${c.agent})`), fail("reply", 900, "acp wait exit 1: Authentication required")], 1).verdict).toBe("pass");
    expect(judge(c, [fail(`start agent (${c.agent})`, 1193, `unknown harness "${c.agent}"`)], 1).verdict).toBe("fail");
    expect(judge(c, [pass(`start agent (${c.agent})`), fail("reply", 120_000, "no reply within 120 s; last: ")], 1).verdict).toBe("fail");
  }
});
