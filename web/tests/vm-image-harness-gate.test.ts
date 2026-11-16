import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ensureOutputFile, harnessEnsureScript, harnessGate, judgeEnsure, pickerHarnesses } from "../scripts/cmux-vm-image/harness-gate";

// The image roll's harness gate (incident 2026-11-16, staging roll run 43919811234): a candidate image is promoted only
// when a booted guest of it passes `acp ensure` for every harness the Cloud chat picker offers.

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** The exact refusal staging guests gave after the 2026-11-16 roll (acpmux model_hint.rs). */
const NO_CLAUDE = `{"error":{"code":"usage","detail":"usage","exit":2,"message":"unknown harness \\"claude\\"; families: chief, unii; profiles: chief, unii; presets: none. \\"claude\\" is a harness profile this host does not have: install it in config.json","promptId":null,"retryable":false,"sessionId":null}}\n@@exit 2\n`;
const STARTED = `{"sessionId":"01a1","state":"ready","harness":"x"}\n@@exit 0\n`;

/**
 * A fixture guest: a `cmux-tui` stand-in whose acpmux has exactly the harnesses in `have`. `acp ensure S -m H` starts H
 * when the guest has it and otherwise refuses the way acpmux does; `acp session stop` succeeds.
 */
function fixtureGuest(have: string[]): { dir: string; cmux: string; out: string } {
  const dir = mkdtempSync(path.join(os.tmpdir(), "harness-gate-"));
  const cmux = path.join(dir, "cmux-tui");
  writeFileSync(
    cmux,
    [
      "#!/bin/sh",
      `have=" ${have.join(" ")} "`,
      'if [ "$1 $2" = "acp ensure" ]; then',
      '  h=""; prev=""; for a in "$@"; do [ "$prev" = -m ] && h="$a"; prev="$a"; done',
      '  case "$have" in *" $h "*) echo "{\\"sessionId\\":\\"s-$h\\",\\"harness\\":\\"$h\\"}"; exit 0 ;; esac',
      '  echo "{\\"error\\":{\\"code\\":\\"usage\\",\\"exit\\":2,\\"message\\":\\"unknown harness \\\\\\"$h\\\\\\"; families: chief, unii\\"}}"; exit 2',
      "fi",
      'if [ "$1 $2 $3" = "acp session stop" ]; then echo closed; exit 0; fi',
      "exit 9",
      "",
    ].join("\n"),
  );
  chmodSync(cmux, 0o755);
  return { dir, cmux, out: path.join(dir, "out") };
}

/** Runs the gate's guest script on a fixture guest and judges what it wrote, as the probe does on the candidate. */
async function runOnFixture(harnesses: readonly string[], have: string[]) {
  const guest = fixtureGuest(have);
  try {
    const script = harnessEnsureScript({ cmux: guest.cmux, cwd: guest.dir, outDir: guest.out, harnesses });
    const status = await new Promise<number | null>((resolve, reject) => {
      const child = spawn("bash", ["-c", script], { stdio: "ignore" });
      child.on("error", reject);
      child.on("close", resolve);
    });
    expect(status).toBe(0);
    const outputs: Record<string, string | undefined> = {};
    for (const h of harnesses) {
      try {
        outputs[h] = readFileSync(ensureOutputFile(guest.out, h), "utf8");
      } catch {
        outputs[h] = undefined;
      }
    }
    return harnessGate(harnesses, outputs);
  } finally {
    rmSync(guest.dir, { recursive: true, force: true });
  }
}

describe("image roll harness gate", () => {
  test("the harnesses come from the Cloud chat picker's list (cloud-chat-matrix.ts PICKER_HARNESSES), never a copy", async () => {
    const matrix = (await import(path.join(HERE, "../../scripts/cmux-next/cloud-chat-matrix.ts"))) as { PICKER_HARNESSES: readonly string[] };
    const harnesses = await pickerHarnesses();
    expect(harnesses).toBe(matrix.PICKER_HARNESSES);
    expect(harnesses).toContain("claude");
    const source = readFileSync(path.join(HERE, "../scripts/cmux-vm-image/harness-gate.ts"), "utf8");
    for (const h of matrix.PICKER_HARNESSES.filter((x) => x !== "claude")) expect(source).not.toContain(`"${h}"`);
  });

  test("a fixture guest whose harness list lacks one picker harness blocks promotion, naming it and its ensure output", async () => {
    const harnesses = await pickerHarnesses();
    const gate = await runOnFixture(harnesses, harnesses.filter((h) => h !== "claude"));
    expect(gate.passed).toBe(false);
    expect(gate.failures.map((f) => f.harness)).toEqual(["claude"]);
    expect(gate.failures[0]!.detail).toContain("claude");
    expect(gate.failures[0]!.detail).toContain('unknown harness \\"claude\\"');
  });

  test("a fixture guest with every picker harness passes", async () => {
    const harnesses = await pickerHarnesses();
    const gate = await runOnFixture(harnesses, [...harnesses]);
    expect(gate.failures).toEqual([]);
    expect(gate.passed).toBe(true);
  });

  test("the incident's exact refusal fails; a harness with no ensure output at all fails", () => {
    const gate = harnessGate(["claude", "codex", "gemini"], { claude: NO_CLAUDE, codex: STARTED, gemini: undefined });
    expect(gate.passed).toBe(false);
    expect(gate.failures.map((f) => f.harness)).toEqual(["claude", "gemini"]);
    expect(gate.failures[0]!.detail).toMatch(/^claude: .*exit 2.*is a harness profile this host does not have/);
    expect(gate.failures[1]!.detail).toMatch(/^gemini: no ensure output/);
  });

  test("an empty harness list never passes", () => {
    expect(harnessGate([], {}).passed).toBe(false);
  });

  test("a signed-out harness is present: its typed sign-in refusal passes; a hang or another refusal fails", () => {
    const signedOut = `{"error":{"code":"runtime","message":"Authentication required","data":{"errorKind":"auth.signed_out"}}}\n@@exit 1\n`;
    expect(judgeEnsure("gemini", signedOut).ok).toBe(true);
    expect(judgeEnsure("gemini", "@@exit 124\n").ok).toBe(false);
    expect(judgeEnsure("grok", `{"error":{"message":"acpmux refused the request"}}\n@@exit 1\n`).ok).toBe(false);
    expect(judgeEnsure("grok", `"grok" is not installed here: install it with cmux harness install grok. Authentication required\n@@exit 2\n`).ok).toBe(false);
    expect(judgeEnsure("codex", "started but no exit line").ok).toBe(false);
    expect(judgeEnsure("codex", STARTED).ok).toBe(true);
  });

  test("the guest script runs acp ensure per harness with the guest's own acpmux home and stops each session", () => {
    const script = harnessEnsureScript({ cmux: "/opt/cmux/cmux-tui", cwd: "/home/cmux/w", outDir: "/tmp/g", harnesses: ["claude", "codex"] });
    expect(script).not.toContain("ACPMUX_HOME=");
    expect(script).toContain("acp ensure 'image-gate-claude' -m 'claude' --cwd '/home/cmux/w' --json");
    expect(script).toContain("acp session stop 'image-gate-codex'");
    expect(() => harnessEnsureScript({ cmux: "c", cwd: "/", outDir: "/tmp", harnesses: ["bad name;rm"] })).toThrow();
  });

  test("the agent tools probe, the image roll's gate before promotion, runs the harness gate", () => {
    const probe = readFileSync(path.join(HERE, "../scripts/cmux-vm-image/agent-tools-probe.ts"), "utf8");
    const body = probe.slice(probe.indexOf("export async function agentToolsProbe"));
    expect(body.slice(0, body.indexOf("\n}\n"))).toContain("await harnessEnsureChecks(");
  });
});
