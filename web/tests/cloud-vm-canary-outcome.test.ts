import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  classifyCodexCanaryOutcome,
  edgeCanaryProblems,
  guestAliasWaitCommand,
  parseGuestAliasWait,
} from "../scripts/cloud-vm/canaryOutcome.mjs";

describe("classifyCodexCanaryOutcome", () => {
  test("accepts the legacy no-account response", () => {
    expect(classifyCodexCanaryOutcome('{"error":"no_usable_account"}', { zeroToken: true })).toBe("no_account");
  });

  test("accepts the OpenAI-shaped no-account response", () => {
    expect(classifyCodexCanaryOutcome(
      '{"error":{"message":"No Codex account is configured","type":"invalid_request_error","code":"no_account_configured"}}',
      { zeroToken: true },
    )).toBe("no_account");
  });

  test("requires an exact pong line for a token-backed turn", () => {
    expect(classifyCodexCanaryOutcome("prompt\npong\ncodex-exit 0", { zeroToken: false })).toBe("answered");
    expect(classifyCodexCanaryOutcome("the answer is pong", { zeroToken: false })).toBe("failed");
  });

  test("does not treat a missing Codex binary as a passing no-account check", () => {
    expect(classifyCodexCanaryOutcome("codex-missing\n{\"error\":\"no_usable_account\"}", { zeroToken: true })).toBe("failed");
  });
});

describe("edgeCanaryProblems", () => {
  test("uses the authenticated edge response instead of a provider hosts marker", () => {
    expect(edgeCanaryProblems({
      tokenOnDisk: null,
      modelsStatus: "200",
      codexOutcome: "no_account",
      claudeCheck: false,
      claudeOutcome: undefined,
    })).toEqual([]);
  });

  test("still fails when the edge contract or guest secret hygiene fails", () => {
    expect(edgeCanaryProblems({
      tokenOnDisk: "/etc/cmux/model-plane.env",
      modelsStatus: "503",
      codexOutcome: "failed",
      codexTail: "coderouter_unavailable",
      claudeCheck: false,
    })).toEqual([
      "route token found in guest files: /etc/cmux/model-plane.env",
      "GET /api/coderouter/vm-usage/self from the guest returned 503",
      "codex turn through the edge did not answer: coderouter_unavailable",
    ]);
  });
});

describe("guest alias wait", () => {
  test("refuses a host that is not a bare host name", () => {
    expect(guestAliasWaitCommand("")).toBeNull();
    expect(guestAliasWaitCommand("coderouter.cmux.internal'; rm -rf /")).toBeNull();
    expect(guestAliasWaitCommand(undefined)).toBeNull();
    expect(guestAliasWaitCommand("coderouter.cmux.internal")).toContain("getent hosts");
  });

  test.skipIf(process.platform !== "linux")("waits for an alias the provider steers late, then reports it", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "canary-alias-"));
    try {
      // getent answers only from its third call, like a guest whose
      // /etc/hosts block lands a second or two after the first exec.
      writeFileSync(path.join(dir, "getent"), `#!/bin/bash\nn=$(cat "${dir}/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "${dir}/count"; [ "$n" -ge 3 ]\n`);
      chmodSync(path.join(dir, "getent"), 0o755);
      const out = execFileSync("bash", ["-c", guestAliasWaitCommand("coderouter.cmux.internal", 10)!], {
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
        encoding: "utf8",
      });
      const report = parseGuestAliasWait(out);
      expect(report.aliasResolved).toBe(true);
      expect(report.aliasWaitMs).toBeGreaterThanOrEqual(900);
      expect(report.guestUptimeS).toBeGreaterThan(0);
      expect(report.hostsBlocks).not.toBeNull();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test.skipIf(process.platform !== "linux")("reports an alias that never resolves within the budget", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "canary-alias-"));
    try {
      writeFileSync(path.join(dir, "getent"), "#!/bin/bash\nexit 2\n");
      chmodSync(path.join(dir, "getent"), 0o755);
      const out = execFileSync("bash", ["-c", guestAliasWaitCommand("coderouter.cmux.internal", 1)!], {
        env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
        encoding: "utf8",
      });
      expect(parseGuestAliasWait(out).aliasResolved).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a guest that never resolved the alias fails the edge check with its evidence", () => {
    expect(edgeCanaryProblems({
      edgeHost: "coderouter.cmux.internal",
      aliasResolved: false,
      aliasWaitMs: 60012,
      guestUptimeS: 71.2,
      hostsBlocks: 0,
      tokenOnDisk: null,
      modelsStatus: "000",
      codexOutcome: "failed",
      codexTail: "curl: (6) Could not resolve host: coderouter.cmux.internal",
      claudeCheck: false,
    })[0]).toBe(
      "guest never resolved coderouter.cmux.internal (waited 60012 ms; guest uptime 71.2 s; freestyle-tls-egress blocks in /etc/hosts: 0)",
    );
  });

  test("parses nothing from an empty report", () => {
    expect(parseGuestAliasWait("")).toEqual({ aliasResolved: null, aliasWaitMs: null, guestUptimeS: null, hostsBlocks: null });
  });
});
