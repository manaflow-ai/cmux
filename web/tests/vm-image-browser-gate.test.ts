import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BROWSER_CHECKS, checkRegressionGate } from "../scripts/cmux-vm-image/harness-gate";

// The agent tools probe's browser check blocks an image roll only on a regression (V0 lead, 2026-11-17): the check
// fails on the candidate and passes on the live image. One already failing on the live image (the intermittent
// "Browser.setPermission timed out after 10000 ms" of rolls 43958052175 and 43971443299) is a named warning.

const HERE = path.dirname(fileURLToPath(import.meta.url));
const TIMEOUT = 'browser_repl_eval: error {"error":{"code":"timeout","message":"Browser.setPermission timed out after 10000 ms"},"state":"in_progress"}';
const pass = (detail = "ok") => ({ ok: true, detail });
const fail = (detail: string) => ({ ok: false, detail });

/** The browser checks of one probe run: `failing` fail with the incident's output, the rest pass. */
function browserRun(failing: readonly string[]): Record<string, { ok: boolean; detail: string }> {
  return Object.fromEntries(BROWSER_CHECKS.map((name) => [name, failing.includes(name) ? fail(name === "mcp-cmux-calls" ? TIMEOUT : `${name} failed`) : pass()]));
}

describe("image roll browser check: only regressions block", () => {
  test("the browser checks are the probe's browser call, its page title and its screenshot", () => {
    expect([...BROWSER_CHECKS]).toEqual(["mcp-cmux-calls", "browser-page-title", "browser-screenshot"]);
  });

  test("a browser check that passes on the live image and fails on the candidate blocks the roll", () => {
    const gate = checkRegressionGate(BROWSER_CHECKS, browserRun(BROWSER_CHECKS), browserRun([]));
    expect(gate.blocking.map((b) => b.check)).toEqual([...BROWSER_CHECKS]);
    expect(gate.blocking[0]!.detail).toContain("Browser.setPermission timed out after 10000 ms");
    expect(gate.blocking[0]!.detail).toContain("passes on the live image");
    expect(gate.warnings).toEqual([]);
  });

  test("a browser check already failing on the live image is a named warning and does not block", () => {
    const gate = checkRegressionGate(BROWSER_CHECKS, browserRun(BROWSER_CHECKS), browserRun(BROWSER_CHECKS));
    expect(gate.blocking).toEqual([]);
    expect(gate.warnings.map((w) => w.check)).toEqual([...BROWSER_CHECKS]);
    expect(gate.warnings[0]!.detail).toContain("already failing on the live image");
    expect(gate.warnings[0]!.detail).toContain("Browser.setPermission timed out after 10000 ms");
  });

  test("with no live result, or none for that check, a candidate failure blocks", () => {
    expect(checkRegressionGate(BROWSER_CHECKS, browserRun(["browser-page-title"]), null).blocking.map((b) => b.check)).toEqual(["browser-page-title"]);
    const partial = browserRun([]);
    delete partial["browser-page-title"];
    const gate = checkRegressionGate(BROWSER_CHECKS, browserRun(["browser-page-title"]), partial);
    expect(gate.blocking.map((b) => b.check)).toEqual(["browser-page-title"]);
    expect(gate.blocking[0]!.detail).toContain("no live image result");
  });

  test("a candidate that passes is neither blocked nor warned, whatever the live image did", () => {
    const gate = checkRegressionGate(BROWSER_CHECKS, browserRun([]), browserRun(BROWSER_CHECKS));
    expect(gate).toEqual({ blocking: [], warnings: [] });
  });

  test("the probe runs the browser checks on its live image clone and applies the gate to the candidate's", () => {
    const probe = readFileSync(path.join(HERE, "../scripts/cmux-vm-image/agent-tools-probe.ts"), "utf8");
    const body = probe.slice(probe.indexOf("export async function agentToolsProbe("), probe.indexOf("export async function main("));
    expect(body).toContain("checkRegressionGate(BROWSER_CHECKS");
    const live = probe.slice(probe.indexOf("async function liveBaseline("), probe.indexOf("export async function agentToolsProbe("));
    expect(live).toContain("callServers(");
    expect(live).toContain("harnessEnsureOutputs(");
  });
});
