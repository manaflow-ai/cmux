#!/usr/bin/env bun
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  validateCapture,
  validateEvidence,
  type BaselineDocument,
  type BudgetConfig,
  type EvidenceDocument,
} from "./validate";
import { formatReport } from "./report";

/** Capture provenance and numbers only; never invent an exception for an over-budget case. */
export function captureBaseline(
  evidence: EvidenceDocument,
  budget: BudgetConfig,
  options: { expectedHead: string; expectedBase: string; artifactUrl: string; evidenceSha256: string },
): BaselineDocument {
  const errors = validateCapture(evidence, budget, options);
  if (!/^https:\/\/github\.com\/manaflow-ai\/cmux\/actions\/runs\/\d+(?:\/artifacts\/\d+)?$/.test(options.artifactUrl))
    errors.push("artifact URL must identify the cmux Actions run or its artifact");
  if (!/^[0-9a-f]{64}$/.test(options.evidenceSha256)) errors.push("evidence SHA256 is invalid");
  if (errors.length) throw new Error(errors.join("\n"));
  const results: BaselineDocument["results"] = {};
  for (const result of evidence.results!)
    results[String(result.id)] = { ...(result.latencyMs as { p50: number; p95: number; max: number }) };
  return {
    schemaVersion: 1,
    status: "ready",
    source: {
      repository: evidence.source!.repository!,
      head: options.expectedHead,
      base: options.expectedBase,
      capturedAt: new Date().toISOString(),
      artifactUrl: options.artifactUrl,
      evidenceSha256: options.evidenceSha256,
    },
    expectedCases: [...evidence.expectedCases!],
    results,
  };
}

function main(args: string[]) {
  const option = (name: string) => {
    const value = args[args.indexOf(name) + 1];
    if (!args.includes(name) || !value || value.startsWith("--")) throw new Error(`missing ${name}`);
    return value;
  };
  const raw = fs.readFileSync(option("--results"));
  const evidence = JSON.parse(raw.toString()) as EvidenceDocument;
  const budget = JSON.parse(fs.readFileSync(option("--budget"), "utf8")) as BudgetConfig;
  const options = {
    expectedHead: option("--expected-head"),
    expectedBase: option("--expected-base"),
    artifactUrl: option("--artifact-url"),
    evidenceSha256: createHash("sha256").update(raw).digest("hex"),
  };
  const baseline = captureBaseline(evidence, budget, options);
  if (budget.rawTraceRequired) {
    const directory = option("--traces");
    for (const result of evidence.results!) {
      const trace = result.rawTrace as { path: string; bytes: number; sha256: string };
      if (path.basename(trace.path) !== trace.path) throw new Error("trace path must be a file name");
      const data = fs.readFileSync(path.join(directory, trace.path));
      if (data.length !== trace.bytes || createHash("sha256").update(data).digest("hex") !== trace.sha256)
        throw new Error(`${String(result.id)}: raw trace artifact digest mismatch`);
      const timeline = JSON.parse(data.toString());
      if (!Array.isArray(timeline.traceEvents) || !timeline.traceEvents.length)
        throw new Error(`${String(result.id)}: raw trace contains no timeline events`);
    }
  }
  const verdict = validateEvidence(evidence, baseline, budget, options);
  fs.writeFileSync(option("--output"), `${JSON.stringify(baseline, null, 2)}\n`);
  fs.writeFileSync(option("--report"), formatReport(verdict));
  console.log(formatReport(verdict));
  // A measured over-budget baseline is retained for diagnosis; activation is blocked.
  if (!verdict.ok) process.exitCode = 1;
}

if (import.meta.main) main(process.argv.slice(2));
