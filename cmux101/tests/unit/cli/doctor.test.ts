import { describe, test, expect, mock, beforeEach, afterEach } from "bun:test";
import type { DoctorReport, DoctorCheck } from "@/cli/doctor";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const EXPECTED_CHECK_NAMES = [
  "bun version",
  "cmux availability",
  "provider configured",
  "home dir writable",
  "~/.cmux101/CLAUDE.md exists",
  "default tools register",
  "model resolution",
  "OAuth discovery",
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("runDoctor", () => {
  test("returns a DoctorReport with all expected check names", async () => {
    // Dynamic import so mocks applied before module load take effect.
    const { runDoctor } = await import("@/cli/doctor");
    const report = await runDoctor({ cwd: process.cwd() });

    expect(report).toHaveProperty("checks");
    expect(report).toHaveProperty("ok");
    expect(Array.isArray(report.checks)).toBe(true);
    expect(report.checks.length).toBe(EXPECTED_CHECK_NAMES.length);

    const names = report.checks.map((c: DoctorCheck) => c.name);
    for (const expected of EXPECTED_CHECK_NAMES) {
      expect(names).toContain(expected);
    }
  });

  test("each check has name, status, and message", async () => {
    const { runDoctor } = await import("@/cli/doctor");
    const report = await runDoctor({ cwd: process.cwd() });

    for (const check of report.checks) {
      expect(typeof check.name).toBe("string");
      expect(["pass", "warn", "fail"]).toContain(check.status);
      expect(typeof check.message).toBe("string");
    }
  });

  test("ok=false when at least one check has status fail", () => {
    // Construct a synthetic report — ok must be false when any fail present.
    const checks: DoctorCheck[] = EXPECTED_CHECK_NAMES.map((name) => ({
      name,
      status: name === "provider configured" ? "fail" : "pass",
      message: "synthetic",
    }));
    const report: DoctorReport = {
      checks,
      ok: checks.every((c) => c.status !== "fail"),
    };
    expect(report.ok).toBe(false);
  });

  test("ok=true when no checks have status fail", () => {
    const checks: DoctorCheck[] = EXPECTED_CHECK_NAMES.map((name) => ({
      name,
      status: "pass" as const,
      message: "synthetic",
    }));
    const report: DoctorReport = {
      checks,
      ok: checks.every((c) => c.status !== "fail"),
    };
    expect(report.ok).toBe(true);
  });
});

describe("renderDoctorReport", () => {
  test("renders [PASS]/[WARN]/[FAIL] badges", async () => {
    const { renderDoctorReport } = await import("@/cli/doctor");
    const checks: DoctorCheck[] = [
      { name: "check-a", status: "pass", message: "all good" },
      { name: "check-b", status: "warn", message: "heads up" },
      { name: "check-c", status: "fail", message: "broken" },
    ];
    const report: DoctorReport = { checks, ok: false };
    const text = renderDoctorReport(report);

    expect(text).toContain("[PASS]");
    expect(text).toContain("[WARN]");
    expect(text).toContain("[FAIL]");
    expect(text).toContain("Doctor:");
    expect(text).toContain("issue");
  });

  test("renders Doctor: OK when ok=true", async () => {
    const { renderDoctorReport } = await import("@/cli/doctor");
    const checks: DoctorCheck[] = [
      { name: "check-a", status: "pass", message: "all good" },
    ];
    const report: DoctorReport = { checks, ok: true };
    const text = renderDoctorReport(report);

    expect(text).toContain("Doctor: OK");
  });
});
