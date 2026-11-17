/**
 * The image roll's harness gate: a candidate Cloud VM image is promoted only when a booted guest of it passes
 * `acp ensure` for every harness the Cloud chat picker offers. agent-tools-probe.ts runs it on its clone of the
 * candidate (the roll's pre-promotion probe); one failing harness fails the probe, so the bake writes no candidate
 * and cloud-vm-image-roll.yml promotes nothing.
 *
 * Incident 2026-11-16: staging image roll run 43919811234 promoted an image, and every `acp ensure` on a new staging
 * guest then failed with exit 2, `unknown harness "claude"; families: chief, unii; ... is a harness profile this
 * host does not have`. The bake's smoke and the agent tools probe had passed: the probe's own `claude` is a recorder
 * under its own ACPMUX_HOME, so nothing asked the guest's real acpmux for the picker's harnesses.
 *
 * The harness list is the picker's, read from scripts/cmux-next/cloud-chat-matrix.ts PICKER_HARNESSES (which the
 * Cloud harness start matrix and cmux-tui's cloud_harness_start.rs follow), never a copy here.
 *
 * A harness passes on a started session (exit 0), or on a typed sign-in refusal (`errorKind: auth.*`): the harness is
 * there and the app then offers its own sign-in, the same rule as the matrix's `start` cells. Anything else fails:
 * an unknown or uninstalled harness, another refusal, a hang (the guest's `timeout` cuts it off) or no output at all.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { sq } from "./lock";

/** How long one harness's ensure may take on the guest (cloud-journey.ts gives ensure 120 s too). */
export const ENSURE_SECONDS = 120;

const MATRIX = fileURLToPath(new URL("../../../scripts/cmux-next/cloud-chat-matrix.ts", import.meta.url));

/** The harnesses the Cloud chat picker offers (cloud-chat-matrix.ts PICKER_HARNESSES). */
export async function pickerHarnesses(): Promise<readonly string[]> {
  // A computed path: web's typecheck stays inside web/, and bun loads the matrix module as it is.
  const matrix = (await import(MATRIX)) as { PICKER_HARNESSES?: readonly string[] };
  if (!Array.isArray(matrix.PICKER_HARNESSES) || matrix.PICKER_HARNESSES.length === 0) throw new Error(`harness gate: ${MATRIX} exports no PICKER_HARNESSES`);
  return matrix.PICKER_HARNESSES;
}

export function ensureOutputFile(outDir: string, harness: string): string {
  return `${outDir}/ensure-${harness}.txt`;
}

function sessionName(harness: string): string {
  return `image-gate-${harness}`;
}

/**
 * The guest script: for each harness, `acp ensure` in a session of its own with the guest's own acpmux (its default
 * ACPMUX_HOME and config, as a person's chat gets), its output and exit into ensureOutputFile, then the session's
 * agent stopped. It always ends 0; harnessGate judges the files.
 */
export function harnessEnsureScript(o: { cmux: string; cwd: string; outDir: string; harnesses: readonly string[] }): string {
  const lines = [`mkdir -p ${sq(o.outDir)}`];
  for (const h of o.harnesses) {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(h)) throw new Error(`harness gate: not a harness id: ${JSON.stringify(h)}`);
    const s = sessionName(h);
    lines.push(
      `{ timeout ${ENSURE_SECONDS} ${sq(o.cmux)} acp ensure ${sq(s)} -m ${sq(h)} --cwd ${sq(o.cwd)} --json; echo "@@exit $?"; } > ${sq(ensureOutputFile(o.outDir, h))} 2>&1`,
      `timeout 30 ${sq(o.cmux)} acp session stop ${sq(s)} > /dev/null 2>&1 || true`,
    );
  }
  lines.push("true", "");
  return lines.join("\n");
}

const MISSING = /unknown harness|not installed here|not set up here|harness profile this host does not have/i;
const SIGNED_OUT = /"errorKind"\s*:\s*"auth\.[a-z_]+"/;

/** One harness's verdict from its ensure output (the text, then `@@exit N`). */
export function judgeEnsure(harness: string, output: string | undefined): { ok: boolean; detail: string } {
  if (output === undefined) return { ok: false, detail: `${harness}: no ensure output (the guest script did not run it)` };
  const exit = /@@exit (\d+)\s*$/.exec(output)?.[1];
  const said = output.replace(/@@exit \d+\s*$/, "").trim().replace(/\s+/g, " ");
  const tail = said.length > 600 ? `...${said.slice(-600)}` : said;
  if (exit === undefined) return { ok: false, detail: `${harness}: acp ensure gave no exit: ${tail}` };
  if (exit === "0") return { ok: true, detail: `${harness}: started` };
  if (exit === "124") return { ok: false, detail: `${harness}: acp ensure did not finish within ${ENSURE_SECONDS} s: ${tail}` };
  if (!MISSING.test(said) && SIGNED_OUT.test(said)) return { ok: true, detail: `${harness}: present, signed out (exit ${exit})` };
  return { ok: false, detail: `${harness}: acp ensure exit ${exit}: ${tail}` };
}

/** The gate: every harness passes, else promotion is blocked and each failure names its harness and output. */
export function harnessGate(harnesses: readonly string[], outputs: Record<string, string | undefined>) {
  const results: Record<string, { ok: boolean; detail: string }> = {};
  for (const h of harnesses) results[h] = judgeEnsure(h, outputs[h]);
  const failures = harnesses.filter((h) => !results[h]!.ok).map((h) => ({ harness: h, detail: results[h]!.detail }));
  return { passed: harnesses.length > 0 && failures.length === 0, failures, results };
}

export type GateNote = { harness: string; detail: string };

/**
 * Only regressions block (V0 lead, after #44718: one broken harness must not freeze every cmux-tui fix). With the live
 * image's outputs from the same ensure, a candidate failure blocks only when that harness passed on the live image; one
 * that already failed there is a warning naming it. With no live result (`null`: none taken, or its clone failed),
 * every candidate failure blocks, as harnessGate does: the gate never passes on missing evidence.
 */
export function regressionGate(harnesses: readonly string[], candidate: Record<string, string | undefined>, live: Record<string, string | undefined> | null) {
  const cand = harnessGate(harnesses, candidate);
  const blocking: GateNote[] = [];
  const warnings: GateNote[] = [];
  for (const f of cand.failures) {
    if (live === null) {
      blocking.push({ harness: f.harness, detail: `${f.detail} (no live image result to compare: blocks)` });
      continue;
    }
    const was = judgeEnsure(f.harness, live[f.harness]);
    if (was.ok) blocking.push({ harness: f.harness, detail: `${f.detail} (passes on the live image: a regression)` });
    else warnings.push({ harness: f.harness, detail: `${f.detail} (already failing on the live image: ${was.detail})` });
  }
  return { passed: harnesses.length > 0 && blocking.length === 0, blocking, warnings, results: cand.results };
}

/** The agent tools probe's browser checks: the cmux MCP's browser call, its page title and its screenshot. */
export const BROWSER_CHECKS = ["mcp-cmux-calls", "browser-page-title", "browser-screenshot"] as const;

export type CheckResult = { ok: boolean; detail: string };
export type CheckNote = { check: string; detail: string };

/**
 * The same rule as regressionGate for probe checks judged on both images: a candidate failure blocks only when the
 * live image passed that check; one already failing there is a warning naming it. With no live result for it (`null`,
 * or the check absent), the failure blocks.
 */
export function checkRegressionGate(names: readonly string[], candidate: Record<string, CheckResult | undefined>, live: Record<string, CheckResult | undefined> | null) {
  const blocking: CheckNote[] = [];
  const warnings: CheckNote[] = [];
  for (const name of names) {
    const c = candidate[name];
    if (!c || c.ok) continue;
    const was = live?.[name];
    if (!was) blocking.push({ check: name, detail: `${c.detail} (no live image result to compare: blocks)` });
    else if (was.ok) blocking.push({ check: name, detail: `${c.detail} (passes on the live image: a regression)` });
    else warnings.push({ check: name, detail: `${c.detail} (already failing on the live image: ${was.detail})` });
  }
  return { blocking, warnings };
}

const AUTO_ROLL = fileURLToPath(new URL("../../../images/cmux-vm/auto-roll.ts", import.meta.url));

/** The live image: production's boot image (auto-roll.ts BOOT_ENTRY) in workers/cmux-vm/wrangler.jsonc at this checkout. */
export async function liveBootImage(): Promise<{ id: string; snapshotId: string }> {
  const roll = (await import(AUTO_ROLL)) as {
    DEFAULT_WRANGLER: string;
    BOOT_ENTRY: Record<string, "first" | "last">;
    locate: (text: string, env: "production") => { images: Array<{ id: string; snapshotId: string }> };
  };
  const images = roll.locate(readFileSync(roll.DEFAULT_WRANGLER, "utf8"), "production").images;
  const entry = roll.BOOT_ENTRY.production === "first" ? images[0] : images[images.length - 1];
  if (!entry) throw new Error("harness gate: production lists no boot image");
  return { id: entry.id, snapshotId: entry.snapshotId };
}
