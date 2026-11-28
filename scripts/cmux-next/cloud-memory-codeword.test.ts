import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { CELLS, judge } from "./cloud-chat-matrix.ts";
import { codeword, deviceHome, instructions, PROMPT, PUSH_STEP, pushDetail, REPLY_STEP, replyNamesCodeword } from "./cloud-memory-codeword.ts";

describe("agent-memory codeword row", () => {
  test("a codeword is fresh per run and never in the prompt", () => {
    const a = codeword(Buffer.from([0, 1, 2, 3, 4]));
    expect(a).toBe("amber-lynx-020304");
    expect(codeword()).not.toBe(codeword());
    expect(PROMPT).not.toContain(a);
  });

  test("the device home holds only the user CLAUDE.md with the codeword", () => {
    const { home } = deviceHome("jade-wren-abcdef");
    expect(readFileSync(path.join(home, ".claude", "CLAUDE.md"), "utf8")).toBe(instructions("jade-wren-abcdef"));
  });

  test("a reply passes only when it names the codeword", () => {
    expect(replyNamesCodeword("jade-wren-abcdef", "jade-wren-abcdef").ok).toBe(true);
    expect(replyNamesCodeword("The codeword is jade-wren-abcdef.", "jade-wren-abcdef").ok).toBe(true);
    expect(replyNamesCodeword("I don't see a codeword in my instructions.", "jade-wren-abcdef").ok).toBe(false);
    expect(replyNamesCodeword("jade-wren", "jade-wren-abcdef").ok).toBe(false);
    expect(replyNamesCodeword("", "jade-wren-abcdef").ok).toBe(false);
  });

  test("a push passes only when the person's own change was accepted", () => {
    expect(pushDetail(0, '{"ok":true,"verb":"push","accepted_revision":4}\n', "").ok).toBe(true);
    expect(pushDetail(0, '{"ok":true,"verb":"push"}\n', "").ok).toBe(false);
    expect(pushDetail(1, "", "error: agent_home.not_found").detail).toContain("agent_home.not_found");
  });

  test("the matrix row fails unless both the push and the reply steps passed", () => {
    const cell = CELLS.find((c) => c.id === "claude-memory-codeword")!;
    expect(cell).toBeDefined();
    expect(cell.must).toEqual([PUSH_STEP, REPLY_STEP]);
    const pass = (step: string) => ({ step, status: "pass" as const, ms: 1 });
    expect(judge(cell, [pass(PUSH_STEP), pass("start agent (claude)"), pass("reply"), pass(REPLY_STEP)], 0).verdict).toBe("pass");
    expect(judge(cell, [pass(PUSH_STEP), pass("start agent (claude)"), pass("reply")], 0).verdict).toBe("fail");
    expect(judge(cell, [pass("start agent (claude)"), pass("reply"), pass(REPLY_STEP)], 0).verdict).toBe("fail");
    expect(judge(cell, [pass(PUSH_STEP), pass("reply"), { step: REPLY_STEP, status: "fail", ms: 1, detail: "no" }], 1).verdict).toBe("fail");
  });
});
