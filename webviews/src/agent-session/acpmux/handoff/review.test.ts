import { describe, expect, test } from "bun:test";
import { reviewedContinuation, sessionEnforcement } from "./review";

describe("human-reviewed handoff", () => {
  test("a git head alone never substitutes for saving the dirty changes", () => {
    expect(() => reviewedContinuation("Continue the task", "HEAD", false, "")).toThrow("checkpoint");
    expect(() => reviewedContinuation("Continue the task", "", true, "")).toThrow("checkpoint");
  });
  test("memory references come only from the review, with no implicit import", () => {
    expect(reviewedContinuation(" Task ", "backup-1", true, "").approvedMemoryReferences).toEqual([]);
    expect(reviewedContinuation(" Task ", "backup-1", true, "project/rules\n\nproject/rules\n user/decision ")).toEqual(
      {
        capsule: " Task ",
        checkpoint: { reference: "backup-1", confirmed: true },
        approvedMemoryReferences: ["project/rules", "user/decision"],
      },
    );
  });
  test("bounds use bytes, and malformed checkpoint/reference values are refused", () => {
    expect(() => reviewedContinuation("🧠".repeat(17_000), "backup", true, "")).toThrow("65536 bytes");
    expect(() => reviewedContinuation("task", "backup\ncommand", true, "")).toThrow("single checkpoint");
    expect(() => reviewedContinuation("task", "backup", true, "x\u0000")).toThrow("memory references");
    expect(() =>
      reviewedContinuation("task", "backup", true, Array.from({ length: 33 }, (_, i) => `ref-${i}`).join("\n")),
    ).toThrow("32");
  });
  test("only strict native-policy reports are accepted", () => {
    for (const value of [undefined, null, {}, { label: "Full access" }, { label: "Full access", detail: "sandboxed" }])
      expect(sessionEnforcement(value)).toBeUndefined();
    const report = { policy: "default", label: "native_policy", isolation: "unverified", detail: null } as const;
    expect(sessionEnforcement(report)).toEqual(report);
  });
  test("uses the owner's byte budget without silently trimming the capsule", () => {
    expect(() => reviewedContinuation(" 🧠 ", "backup", true, "", 5)).toThrow("5 bytes");
    expect(reviewedContinuation(" 🧠 ", "backup", true, "", 6).capsule).toBe(" 🧠 ");
  });
});
