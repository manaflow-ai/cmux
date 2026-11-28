#!/usr/bin/env bun
/**
 * Is AutoCloud ready? Three pass/fail rows: mark, instant start, sync (autocloud-readiness-report.ts has the rules).
 *
 * Leo, 2026-11-27 22:57Z: "hey is autocloud working? we need to get a sense of where we're all at and if it works and
 * what we need to get it working. we're trying to cut an rc but we absolutely need to just like... go"
 *
 * It runs the storage sync probe (autocloud-sync-probe.ts: one scratch chat toggled onto a Cloud machine, edits both
 * ways, toggled home) and reads its row as the three rows, or reads a row a probe run already wrote:
 *
 *   bun scripts/cmux-next/autocloud-readiness.ts --acpmux PATH/acpmux [--backend staging] [--out DIR]
 *   bun scripts/cmux-next/autocloud-readiness.ts --from RESULT.json
 *       [--markdown FILE] [--json FILE]
 *
 * The run needs the probe's credentials (CLOUD_PROBE_PRODUCTION_STACK_EMAIL and _PASSWORD; with --backend staging,
 * CMUX_DOGFOOD_STACK_EMAIL and _PASSWORD) and a Linux or macOS acpmux (the NIGHTLY's:
 * .github/workflows/autocloud-readiness.yml fetches it). Prints the rows; exit 0 only when all three pass, 1 when one
 * does not. Writes no token: the probe's row is scrubbed, and the report holds only its steps' details.
 */
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { markdown, readiness, text } from "./autocloud-readiness-report.ts";

const argValue = (name: string): string | undefined => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
};

function main(): number {
  const from = argValue("--from");
  let resultFile: string;
  if (from) {
    resultFile = path.resolve(from);
  } else {
    const out = path.resolve(argValue("--out") ?? "autocloud-readiness-out");
    mkdirSync(out, { recursive: true });
    resultFile = path.join(out, "sync-probe.json");
    const probe = path.join(path.dirname(fileURLToPath(import.meta.url)), "autocloud-sync-probe.ts");
    const pass: string[] = [];
    for (const flag of ["--acpmux", "--cmux", "--backend"]) {
      const v = argValue(flag);
      if (v !== undefined) pass.push(flag, v);
    }
    // The probe's own step lines go to stderr here, so stdout is the report alone.
    const r = spawnSync(process.execPath, [probe, ...pass, "--out", path.join(out, "probe"), "--result", resultFile], {
      stdio: ["ignore", process.stderr, process.stderr],
      env: process.env,
      timeout: 13 * 60_000,
    });
    if (r.error) console.error(`autocloud-readiness: the probe did not run: ${r.error.message}`);
  }
  const row = existsSync(resultFile)
    ? (JSON.parse(readFileSync(resultFile, "utf8")) as Record<string, unknown>)
    : { outcome: "fail", error: `the probe wrote no row at ${resultFile}` };
  const report = readiness(row);
  process.stdout.write(text(report));
  const md = argValue("--markdown");
  if (md) writeFileSync(md, markdown(report));
  const js = argValue("--json");
  if (js) writeFileSync(js, JSON.stringify(report, null, 2) + "\n");
  return report.outcome === "pass" ? 0 : 1;
}

if (import.meta.main) process.exit(main());
