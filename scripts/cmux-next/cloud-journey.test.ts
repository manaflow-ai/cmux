import { describe, expect, test } from "bun:test";
import { newReds, readEnvFile, resolveBackend, scrub, summaryMarkdown } from "./cloud-journey";

describe("cloud journey", () => {
  test("backend names map to the cmux API Worker of each environment", () => {
    expect(resolveBackend("staging").api).toBe("https://cloud-api-staging.cmux.dev");
    expect(resolveBackend("prod")).toEqual({ name: "prod", api: "https://cloud-api.cmux.dev", stack: "prod" });
    expect(resolveBackend("preview-35100").api).toBe("https://cmux-api-preview-35100.debussy.workers.dev");
    expect(resolveBackend("preview-leo1").stack).toBe("dev");
    expect(resolveBackend("local", undefined, undefined, 9000).api).toBe("http://127.0.0.1:9000");
    expect(resolveBackend("custom", "https://x.example/", "prod")).toEqual({ name: "custom", api: "https://x.example", stack: "prod" });
    expect(() => resolveBackend("classic")).toThrow();
    expect(() => resolveBackend("preview-A_B")).toThrow();
  });
  test("secrets never reach the output", () => {
    const out = scrub("token eyJabcdefghijk.payload Bearer abc cmuxvm_sk_0123456789 pw hunter22", ["hunter22"]);
    expect(out).not.toContain("eyJabcdefghijk");
    expect(out).not.toContain("cmuxvm_sk_0123456789");
    expect(out).not.toContain("hunter22");
    expect(out).not.toMatch(/Bearer abc/);
  });
  test("env files and the summary table", () => {
    expect(readEnvFile("export A='1'\nB=\"two\"\n# c\n")).toEqual({ A: "1", B: "two" });
    const md = summaryMarkdown(resolveBackend("staging"), [
      { step: "health", status: "pass", ms: 10, detail: "a|b" },
      { step: "reply", status: "fail", ms: 5, detail: "x" },
    ]);
    expect(md.startsWith("FAIL")).toBe(true);
    expect(md).toContain("| **FAIL** | reply | 5 | x |");
    expect(md).toContain("a\\|b");
  });

  test("newReds: only steps the deploy turned red", () => {
    const st = (step: string, status: "pass" | "fail" | "skip") => ({ step, status, ms: 1, detail: "" });
    const before = [st("health", "pass"), st("create machine", "pass"), st("running (status)", "fail")];
    const after = [st("health", "fail"), st("create machine", "pass"), st("running (status)", "fail")];
    // running (status) was already red before the deploy (a known bug): not a rollback.
    expect(newReds(before, after).map((s) => s.step)).toEqual(["health"]);
    expect(newReds(before, [st("health", "pass"), st("running (status)", "fail")])).toEqual([]);
    // No baseline: every failed step counts.
    expect(newReds(null, after).map((s) => s.step)).toEqual(["health", "running (status)"]);
  });
});
