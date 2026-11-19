import { describe, expect, test } from "bun:test";
import { CELLS } from "./cloud-chat-matrix.ts";
import { BREAK_LEGS, judgeRefusal, judgeTwinCreate, parseBreak, sendOutcome, twinSent } from "./cloud-journey-break.ts";

describe("parseBreak", () => {
  test("all is every leg; none is empty", () => {
    expect([...parseBreak("all")].sort()).toEqual([...BREAK_LEGS].sort());
    expect(parseBreak(undefined).size).toBe(0);
  });
  test("a typo throws instead of passing", () => {
    expect(() => parseBreak("empty-prompt,huge-promt")).toThrow(/huge-promt/);
  });
});

describe("judgeRefusal", () => {
  test("accepted is for the caller to finish", () => {
    expect(judgeRefusal({ exit: 0, said: "", ms: 30 })).toBeNull();
  });
  test("a fast refusal that names the problem passes", () => {
    expect(judgeRefusal({ exit: 2, said: "error: the prompt is empty; type something to send", ms: 40 })?.ok).toBe(true);
    expect(judgeRefusal({ exit: 1, said: "prompt too large: at most 200000 bytes", ms: 90 })?.ok).toBe(true);
  });
  test("a silent, wordless or slow refusal fails", () => {
    expect(judgeRefusal({ exit: 1, said: "", ms: 40 })?.ok).toBe(false);
    expect(judgeRefusal({ exit: 1, said: "internal error", ms: 40 })?.ok).toBe(false);
    expect(judgeRefusal({ exit: 1, said: "prompt is empty", ms: 30_000 })?.ok).toBe(false);
  });
});

test("sendOutcome reads the program's markers", () => {
  expect(sendOutcome("queued\n@@exit 0\n@@ms 12\n", 999)).toEqual({ exit: 0, said: "queued", ms: 12 });
  expect(sendOutcome("boom", 77)).toEqual({ exit: 1, said: "boom", ms: 77 });
});

test("twinSent needs exit 0 for each session", () => {
  expect(twinSent("@@sent a-t1 0\n@@sent a-t2 1\n", ["a-t1", "a-t2"])).toEqual(["a-t1"]);
  expect(twinSent("@@sent a-t1 0\n@@sent a-t2 0\n", ["a-t1", "a-t2"])).toEqual(["a-t1", "a-t2"]);
});

describe("judgeTwinCreate", () => {
  test("both made passes", () => {
    expect(judgeTwinCreate({ ok: true, why: "vm_a" }, { ok: true, why: "vm_b running" }).ok).toBe(true);
  });
  test("a cap refusal with a next step passes; a bare error fails", () => {
    expect(judgeTwinCreate({ ok: true, why: "vm_a" }, { ok: false, why: "cloud.machine_cap: your plan holds 5 machines; delete one or upgrade" }).ok).toBe(true);
    expect(judgeTwinCreate({ ok: true, why: "vm_a" }, { ok: false, why: "HTTP 500 internal" }).ok).toBe(false);
  });
});

test("break cells exist and stay out of the default run", () => {
  const ids = CELLS.filter((c) => c.id.startsWith("break-")).map((c) => c.id);
  expect(ids).toEqual(["break-claude-stub", "break-codex-stub"]);
  for (const c of CELLS.filter((x) => x.id.startsWith("break-"))) expect(c.args).toContain("--break");
});
