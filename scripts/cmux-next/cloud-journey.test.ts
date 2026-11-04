import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { claudeLoginPrograms, loginBearer, loginPrograms, stubCodexAuth, validLogin, INSTALLER_SWIFT, JOURNEY_STUB_SCRIPT, MODEL_STUB_PY, newReds, probeRow, readEnvFile, resolveBackend, scrub, summaryMarkdown, swiftRawString } from "./cloud-journey";
import { nativeProofSkip, oidcSignIn } from "./cloud-journey";

describe("cloud journey", () => {
  test("--sign-in oidc trades the job's OIDC token for the API's session and keeps both out of the output", async () => {
    const calls: Array<{ method: string; url: string; auth: string }> = [];
    const fake = async (method: string, url: string, _body: unknown, headers: Record<string, string>) => {
      calls.push({ method, url, auth: headers.authorization ?? "" });
      if (url.startsWith("https://gh.example/token")) return { status: 200, body: { value: "gh-oidc-jwt-value" } };
      return { status: 200, body: { access_token: "stack-access-value", user: "user_x", session_expires_at: "2026-11-04T18:00:00.000Z" } };
    };
    const secrets: string[] = [];
    const s = await oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/token?x=1", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "request-bearer" }, secrets, fake as never);
    expect(s).toEqual({ token: "stack-access-value", user: "user_x", expiresAt: "2026-11-04T18:00:00.000Z" });
    expect(calls[0]).toEqual({ method: "GET", url: "https://gh.example/token?x=1&audience=https%3A%2F%2Fcloud-api.cmux.dev", auth: "bearer request-bearer" });
    expect(calls[1]).toEqual({ method: "POST", url: "https://cloud-api.cmux.dev/v1/auth/github-actions", auth: "Bearer gh-oidc-jwt-value" });
    expect(secrets).toEqual(["request-bearer", "gh-oidc-jwt-value", "stack-access-value"]);
    await expect(oidcSignIn("https://cloud-api.cmux.dev", {}, [], fake as never)).rejects.toThrow("id-token: write");
    const refused = async () => ({ status: 401, body: { error: "this token is not trusted to sign in", value: "gh-oidc-jwt-value" } });
    await expect(oidcSignIn("https://cloud-api.cmux.dev", { ACTIONS_ID_TOKEN_REQUEST_URL: "https://gh.example/t", ACTIONS_ID_TOKEN_REQUEST_TOKEN: "rb" }, [], refused as never)).rejects.toThrow("GitHub OIDC token HTTP 401");
  });
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
  test("the login copy runs the Mac installer's own programs", () => {
    expect(swiftRawString('  static let x = #"""\n      a\n        b\n      """#', "x")).toBe("a\n  b");
    const programs = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"));
    expect(programs.preflight.startsWith("set -eu\n")).toBe(true);
    expect(programs.preflight).toContain("/etc/cmux/vm-kind");
    const install = programs.install("/home/cmux/.cmux/credential-transfer/A.json");
    expect(install).toContain("python3 - 'claude' '/home/cmux/.cmux/credential-transfer/A.json' owner <<'CMUX_CREDENTIAL_INSTALL'\nimport json, os");
    expect(install).toContain("env['CLAUDE_CODE_OAUTH_TOKEN'] = value");
    expect(install.endsWith("\nCMUX_CREDENTIAL_INSTALL")).toBe(true);
  });
  test("a run is one probe row", () => {
    const at = new Date("2026-11-04T11:00:00.123Z");
    const ok = probeRow("cloud-chat-replies-production", [
      { step: "send chat", status: "pass", ms: 800, detail: "" },
      { step: "reply", status: "pass", ms: 4200, detail: "Earth." },
    ], "https://x/runs/1", at);
    expect(ok).toEqual({ probe: "cloud-chat-replies-production", at: "2026-11-04T11:00:00Z", runner: "github-actions", run: "https://x/runs/1", outcome: "ok", ms: 5000 });
    const bad = probeRow("p", [{ step: "create machine", status: "fail", ms: 5, detail: "HTTP 503" }], undefined, at);
    expect(bad).toMatchObject({ outcome: "fail", error: "create machine: HTTP 503" });
  });
  test("the journey's stub script is valid for the shared model stub and its reply repeats the tool output", () => {
    expect(readFileSync(MODEL_STUB_PY, "utf8")).toContain("--ready-file");
    expect(JOURNEY_STUB_SCRIPT.steps[0].shell).not.toContain("{{nonce}}-tool");
    expect(JOURNEY_STUB_SCRIPT.steps[1].text).toContain("{{result.0}}");
  });
  test("a team machine gets the DEV creator allowance, as a nightly build copies", () => {
    const team = claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), true);
    expect(team.preflight).toContain("owner|team");
    expect(team.install("/p.json")).toContain("'/p.json' owner,team <<");
    expect(claudeLoginPrograms(readFileSync(INSTALLER_SWIFT, "utf8")).install("/p.json")).toContain("'/p.json' owner <<");
  });
  test("Codex: the made-up sign-in passes the app's validation and the installer gets the codex provider", () => {
    const auth = stubCodexAuth("ab".repeat(16), new Date("2026-11-04T00:00:00Z"));
    expect(validLogin("codex", auth)).toBe(true);
    expect(validLogin("codex", JSON.stringify({ OPENAI_API_KEY: "sk-x", tokens: {} }))).toBe(false);
    expect(validLogin("claude", auth)).toBe(false);
    expect(loginBearer("codex", auth)).toBe(JSON.parse(auth).tokens.access_token);
    expect(loginPrograms(readFileSync(INSTALLER_SWIFT, "utf8"), "codex").install("/p.json")).toContain("python3 - 'codex' '/p.json' owner <<");
  });
});

describe("cloud journey: link_token on a Native machine", () => {
  const refusal = (code: string, reason?: string) => ({ ok: false, error: { code, message: "m", ...(reason ? { details: { reason } } : {}) } });
  test("skips only a refusal for want of a Native device enrollment", () => {
    for (const reason of ["host_missing", "host_unconfirmed", "proof_missing"])
      expect(nativeProofSkip(refusal("auth.forbidden", reason))).toContain(`needs a Native device proof (app-only): link_token refused ${reason}`);
  });
  test("keeps every other answer red", () => {
    expect(nativeProofSkip(refusal("auth.forbidden"))).toBeNull(); // an older backend names no check
    expect(nativeProofSkip(refusal("auth.forbidden", "vm_services"))).toBeNull();
    expect(nativeProofSkip(refusal("auth.forbidden", "host_grant"))).toBeNull();
    expect(nativeProofSkip(refusal("owner.unreachable", "host_missing"))).toBeNull();
    expect(nativeProofSkip({ ok: true, value: { expires_at: 1 } })).toBeNull();
    expect(nativeProofSkip(undefined)).toBeNull();
  });
});
