import { describe, expect, test } from "bun:test";
import { authBlocker, matrixMarkdown, parallelCell, rowFromSteps } from "./cloud-claude-matrix.ts";

const step = (name: string, status: "pass" | "fail" | "skip", ms = 1000, detail = "ok") => ({ step: name, status, ms, detail });

describe("cloud chat matrix", () => {
  test("a green journey fills first, follow-up and resume, with create→reply", () => {
    const row = rowFromSteps("sr2", "sonnet", [
      step("create machine", "pass", 2000),
      step("running (status)", "pass", 1000),
      step("reply", "pass", 3000, "matrix sr2 sonnet is here."),
      step("session model", "pass", 100, "asked claude-sonnet-5-5; the session runs claude-sonnet-5-5"),
      step("turn 2 (same session)", "pass"),
      step("turn after resume", "pass"),
    ], 0);
    expect(row.cells.first.status).toBe("pass");
    expect(row.cells.followup.status).toBe("pass");
    expect(row.cells.resume.status).toBe("pass");
    expect(row.replyMs).toBe(3000);
    expect(row.createToReplyMs).toBe(6000);
  });

  test("the wrong model fails the first chat even when a reply came back", () => {
    const row = rowFromSteps("sr2", "haiku", [step("reply", "pass"), step("session model", "fail", 10, "asked claude-haiku-5-5; the session runs claude-opus-5-5")], 1);
    expect(row.cells.first.status).toBe("fail");
    expect(row.cells.first.detail).toContain("claude-opus-5-5");
  });

  test("cells after a failed step say which step stopped them", () => {
    const row = rowFromSteps("sr2", "opus", [step("create machine", "pass"), step("reply", "fail", 1, "Not logged in")], 1);
    expect(row.cells.first).toEqual({ status: "fail", detail: "Not logged in" });
    expect(row.cells.followup.detail).toContain("reply failed");
  });

  test("parallel needs two concurrent replies", () => {
    const ok = rowFromSteps("sr2", "opus", [step("reply", "pass")], 0);
    const bad = rowFromSteps("sr2", "haiku", [step("reply", "fail")], 1);
    expect(parallelCell([ok, ok]).status).toBe("pass");
    expect(parallelCell([ok, bad]).status).toBe("fail");
    expect(parallelCell([ok]).status).toBe("skip");
  });

  test("absent credentials skip, never pass", () => {
    expect(authBlocker("sr2", {})).toBeNull();
    expect(authBlocker("subscription", {})).toContain("CLAUDE_CODE_OAUTH_TOKEN");
    expect(authBlocker("subscription", { CLAUDE_CODE_OAUTH_TOKEN: "x" })).toBeNull();
    expect(authBlocker("api-key", {})).toContain("ANTHROPIC_API_KEY");
    expect(authBlocker("team-key", {})).toContain("CMUX_MATRIX_TEAM_KEY_TEAM");
  });

  test("the table marks failures and explains non-pass cells", () => {
    const row = rowFromSteps("sr2", "opus", [step("reply", "fail", 1, "Not logged in")], 1);
    const md = matrixMarkdown("prod", [row]);
    expect(md.startsWith("FAIL")).toBe(true);
    expect(md).toContain("**FAIL**");
    expect(md).toContain("sr2 opus first: fail: Not logged in");
  });
});
