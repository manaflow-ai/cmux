// cloud-flows.ts without a browser or the network: every flow file reads, a step without its secrets is a named skip,
// the TOTP code matches RFC 6238, GitHub's pages are told apart by URL, and a flow of skips passes.
import { describe, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fill, githubPage, missingNeed, readFlow, runFlow, totp } from "./cloud-flows";
import { resolveBackend } from "./cloud-journey";

const FLOWS = join(import.meta.dir, "flows");

describe("cloud-flows", () => {
  test("every flow file reads", () => {
    const files = readdirSync(FLOWS).filter((f) => f.endsWith(".json"));
    expect(files).toContain("github-connect.json");
    expect(files).toContain("cloud-first-chat.json");
    for (const f of files) expect(readFlow(join(FLOWS, f)).steps.length).toBeGreaterThan(0);
  });

  test("a step without its secrets names them", () => {
    const step = { id: "x", title: "x", do: "sign-in", needs: ["staging-account"] };
    expect(missingNeed(step, {})).toBe("needs staging account: secrets absent (CMUX_DOGFOOD_STACK_EMAIL, CMUX_DOGFOOD_STACK_PASSWORD)");
    expect(missingNeed(step, { CMUX_DOGFOOD_STACK_EMAIL: "a", CMUX_DOGFOOD_STACK_PASSWORD: "b" })).toBeNull();
  });

  test("totp matches RFC 6238's SHA-1 vector", () => {
    // RFC 6238 appendix B: seed "12345678901234567890", T = 59 s gives 94287082 (its last six digits here).
    expect(totp("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", 59_000)).toBe("287082");
  });

  test("fill and githubPage", () => {
    expect(fill("https://github.com/{org}/{repo}", { org: "o", repo: "r" })).toBe("https://github.com/o/r");
    expect(githubPage("https://github.com/login?return_to=x")).toBe("login");
    expect(githubPage("https://github.com/sessions/two-factor/app")).toBe("2fa");
    expect(githubPage("https://github.com/apps/a/installations/new")).toBe("install");
    expect(githubPage("https://example.com/")).toBe("left");
  });

  test("a flow whose every step lacks its secrets passes with named skips", async () => {
    const out = mkdtempSync(join(tmpdir(), "cloud-flows-test-"));
    const flow = readFlow(join(FLOWS, "github-connect.json"));
    const offline = { ...flow, steps: flow.steps.filter((s) => (s.needs ?? []).length > 0) };
    expect(await runFlow(offline, resolveBackend("staging"), out, {})).toBe(0);
    const summary = readFileSync(join(out, "summary.md"), "utf8");
    expect(summary).toContain("PASS github-connect on staging: 0 passed, 0 failed");
    expect(summary).toContain("skipped for absent secrets: staging account, GitHub test user, Claude login");
  });
});
