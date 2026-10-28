#!/usr/bin/env bun
/** Strict, fail-closed validator for the v1 Chromium latency evidence. */
// @ts-ignore Bun supplies the Node fs shim at runtime; webviews intentionally has no @types/node.
import fs from "node:fs";
import { formatReport } from "./report";

declare const process: {
  argv: string[];
  env: Record<string, string | undefined>;
  exitCode?: number;
};

export interface BudgetConfig {
  schemaVersion: 1;
  maxP95Ms: number;
  maxRegressionRatio: number;
  maxRegressionDeltaMs: number;
  topN: number;
}

export interface BaselineResult {
  p50: number;
  p95: number;
  max: number;
  fixingPr?: string;
}

export interface BaselineDocument {
  schemaVersion: 1;
  status: "pending" | "ready";
  reason?: string;
  source: { repository: string; head: string; base?: string; capturedAt?: string } | null;
  expectedCases?: string[];
  results: Record<string, BaselineResult>;
}

export interface EvidenceDocument {
  schemaVersion: number;
  source?: {
    repository?: string;
    head?: string;
    base?: string;
    browsers?: Array<{ engine?: string; version?: string }>;
    runner?: { platform?: string };
    mode?: string;
    dirty?: boolean;
  };
  expectedCases?: string[];
  runs?: number;
  results?: Array<Record<string, unknown>>;
  errors?: unknown;
}

export interface ReportRow {
  id: string;
  p50: number | null;
  p95: number | null;
  max: number | null;
  baselineP95: number | null;
  allowedP95: number | null;
  status: "pass" | "over-budget" | "regression" | "fixing-pr" | "missing" | "invalid";
  fixingPr?: string;
}

export interface ValidationResult {
  ok: boolean;
  errors: string[];
  warnings: string[];
  rows: ReportRow[];
  head: string | null;
  base: string | null;
}

const SHA = /^[0-9a-f]{40}$/;
const isFiniteNumber = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function readJson(path: string): unknown {
  try {
    return JSON.parse(fs.readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${path}: cannot read JSON (${String(error).split("\n")[0]})`);
  }
}

function validDistribution(value: unknown): value is { p50: number; p95: number; max: number } {
  if (!isRecord(value) || !isFiniteNumber(value.p50) || !isFiniteNumber(value.p95) || !isFiniteNumber(value.max))
    return false;
  return value.p50 >= 0 && value.p95 >= value.p50 && value.max >= value.p95;
}

function validFixingPr(value: unknown): value is string {
  return typeof value === "string" && /(?:https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+|#\d+)/.test(value);
}

function validateBudget(value: unknown, errors: string[]): value is BudgetConfig {
  const before = errors.length;
  if (!isRecord(value) || value.schemaVersion !== 1) {
    errors.push("budget must declare schemaVersion 1");
    return false;
  }
  for (const key of ["maxP95Ms", "maxRegressionRatio", "maxRegressionDeltaMs", "topN"])
    if (!isFiniteNumber(value[key]) || Number(value[key]) < 0)
      errors.push(`budget.${key} must be a finite non-negative number`);
  if (isFiniteNumber(value.topN) && (!Number.isInteger(value.topN) || value.topN < 1))
    errors.push("budget.topN must be a positive integer");
  if (isFiniteNumber(value.maxP95Ms) && value.maxP95Ms <= 0) errors.push("budget.maxP95Ms must be positive");
  return errors.length === before;
}

function validateBaseline(value: unknown, errors: string[]): value is BaselineDocument {
  if (!isRecord(value) || value.schemaVersion !== 1 || (value.status !== "pending" && value.status !== "ready")) {
    errors.push("baseline must declare schemaVersion 1 and status pending or ready");
    return false;
  }
  if (value.status === "pending") {
    errors.push(
      `baseline is pending: ${typeof value.reason === "string" ? value.reason : "capture the first hosted Linux Chromium run"}`,
    );
    return false;
  }
  if (!isRecord(value.source) || typeof value.source.head !== "string" || !SHA.test(value.source.head))
    errors.push("baseline source.head must be a full commit SHA");
  if (!isRecord(value.results)) errors.push("baseline.results must be an object");
  else {
    for (const [id, item] of Object.entries(value.results)) {
      if (!isRecord(item) || !validDistribution(item)) errors.push(`baseline ${id}: invalid p50/p95/max distribution`);
      if (isRecord(item) && item.fixingPr !== undefined && !validFixingPr(item.fixingPr))
        errors.push(`baseline ${id}: fixingPr must be a GitHub pull request URL or #number`);
    }
  }
  return errors.length === 0;
}

function parseEvidence(value: unknown, expectedHead: string | undefined, errors: string[]): EvidenceDocument | null {
  if (!isRecord(value)) {
    errors.push("results must be a JSON object");
    return null;
  }
  const evidence = value as unknown as EvidenceDocument;
  if (evidence.schemaVersion !== 1) errors.push("results must declare schemaVersion 1");
  const source = evidence.source;
  if (!source || typeof source.head !== "string" || !SHA.test(source.head))
    errors.push("source.head must be a full commit SHA");
  if (!source || typeof source.base !== "string" || !SHA.test(source.base))
    errors.push("source.base must be a full commit SHA");
  if (expectedHead && source?.head !== expectedHead)
    errors.push(`results head ${source?.head ?? "missing"} does not match expected ${expectedHead}`);
  if (source?.mode !== "production") errors.push("results must be production mode evidence");
  if (source?.dirty !== false) errors.push("results source.dirty must be false");
  if (source?.runner?.platform !== "linux") errors.push("results runner.platform must be linux");
  if (!source?.browsers?.length || source.browsers.some((browser) => browser.engine !== "chromium"))
    errors.push("results must contain only Chromium browser evidence");
  if (!Array.isArray(evidence.expectedCases) || evidence.expectedCases.length === 0)
    errors.push("expectedCases is empty or missing");
  if (Array.isArray(evidence.expectedCases) && new Set(evidence.expectedCases).size !== evidence.expectedCases.length)
    errors.push("expectedCases contains duplicate IDs");
  if (!Number.isInteger(evidence.runs) || (evidence.runs ?? 0) < 1) errors.push("runs must be a positive integer");
  if (!Array.isArray(evidence.results)) errors.push("results.results must be an array");
  if (!Array.isArray(evidence.errors)) errors.push("results.errors must be an array");
  else if (evidence.errors.length) errors.push(...evidence.errors.map((error) => `harness: ${String(error)}`));
  return evidence;
}

function inspectResult(result: Record<string, unknown>, errors: string[]): boolean {
  const id = typeof result.id === "string" ? result.id : "<missing id>";
  let valid = true;
  if (result.engine !== "chromium") errors.push(`${id}: result.engine must be chromium`);
  if (!validDistribution(result.latencyMs)) {
    errors.push(`${id}: invalid latencyMs distribution`);
    valid = false;
  }
  if (!Array.isArray(result.samples) || result.samples.length === 0) {
    errors.push(`${id}: samples are empty`);
    valid = false;
  }
  if (!Array.isArray(result.errors) || result.errors.length)
    errors.push(`${id}: result.errors is non-empty or missing`);
  const longTasks = result.longTasks;
  if (
    !isRecord(longTasks) ||
    !isFiniteNumber(longTasks.count) ||
    !Number.isInteger(longTasks.count) ||
    longTasks.count < 0 ||
    !isFiniteNumber(longTasks.totalMs) ||
    !isFiniteNumber(longTasks.maxMs)
  ) {
    errors.push(`${id}: required longTasks instrumentation is missing or invalid`);
    valid = false;
  }
  if (!isFiniteNumber(result.reactCommits) || !Number.isInteger(result.reactCommits) || result.reactCommits < 0) {
    errors.push(`${id}: required reactCommits instrumentation is missing or invalid`);
    valid = false;
  }
  const idle = result.idle;
  if (!isRecord(idle) || !isFiniteNumber(idle.cpuDurationMs) || idle.cpuDurationMs < 0) {
    errors.push(`${id}: required idle.cpuDurationMs instrumentation is missing or invalid`);
    valid = false;
  }
  if (
    isRecord(idle) &&
    idle.wakeups === null &&
    (!isRecord(result.unsupportedReasons) || typeof result.unsupportedReasons.wakeups !== "string")
  )
    errors.push(`${id}: null wakeups must include an explicit unsupported reason`);
  if (!isRecord(result.framesSummary)) errors.push(`${id}: framesSummary is missing`);
  return valid;
}

export function validateEvidence(
  evidence: unknown,
  baseline: unknown,
  budget: unknown,
  options: { expectedHead?: string } = {},
): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];
  const parsed = parseEvidence(evidence, options.expectedHead, errors);
  const baselineErrors: string[] = [];
  const baselineShapeValid = validateBaseline(baseline, baselineErrors);
  errors.push(...baselineErrors);
  const budgetErrors: string[] = [];
  const budgetShapeValid = validateBudget(budget, budgetErrors);
  errors.push(...budgetErrors);
  const baselineDoc = baselineShapeValid ? (baseline as BaselineDocument) : null;
  const budgetDoc = budgetShapeValid ? (budget as BudgetConfig) : null;
  const head = typeof parsed?.source?.head === "string" ? parsed.source.head : null;
  const base = typeof parsed?.source?.base === "string" ? parsed.source.base : null;
  const rows: ReportRow[] = [];
  if (parsed && Array.isArray(parsed.expectedCases) && Array.isArray(parsed.results)) {
    const byId = new Map<string, Record<string, unknown>>();
    for (const result of parsed.results) {
      if (!isRecord(result) || typeof result.id !== "string") {
        errors.push("result is missing a stable id");
        continue;
      }
      if (byId.has(result.id)) errors.push(`duplicate result: ${result.id}`);
      byId.set(result.id, result);
      if (!parsed.expectedCases.includes(result.id)) errors.push(`unexpected result: ${result.id}`);
    }
    for (const id of parsed.expectedCases) {
      const result = byId.get(id);
      if (!result) {
        errors.push(`missing result: ${id}`);
        rows.push({ id, p50: null, p95: null, max: null, baselineP95: null, allowedP95: null, status: "missing" });
        continue;
      }
      const valid = inspectResult(result, errors);
      const distribution = validDistribution(result.latencyMs) ? result.latencyMs : null;
      const prior = baselineDoc?.results[id];
      if (!prior) {
        errors.push(`${id}: baseline result is missing`);
        rows.push({
          id,
          p50: distribution?.p50 ?? null,
          p95: distribution?.p95 ?? null,
          max: distribution?.max ?? null,
          baselineP95: null,
          allowedP95: null,
          status: "missing",
        });
        continue;
      }
      const allowedP95 = budgetDoc
        ? prior.p95 * (1 + budgetDoc.maxRegressionRatio) + budgetDoc.maxRegressionDeltaMs
        : null;
      const fixingPr = prior.fixingPr;
      if (distribution && allowedP95 !== null && distribution.p95 > allowedP95 && !fixingPr)
        errors.push(
          `${id}: p95 ${distribution.p95.toFixed(1)}ms exceeds regression allowance ${allowedP95.toFixed(1)}ms`,
        );
      rows.push({
        id,
        p50: distribution?.p50 ?? null,
        p95: distribution?.p95 ?? null,
        max: distribution?.max ?? null,
        baselineP95: prior.p95,
        allowedP95,
        fixingPr,
        status: !valid
          ? "invalid"
          : fixingPr &&
              distribution &&
              ((budgetDoc && distribution.p95 > budgetDoc.maxP95Ms) ||
                (allowedP95 !== null && distribution.p95 > allowedP95))
            ? "fixing-pr"
            : distribution && budgetDoc && distribution.p95 > budgetDoc.maxP95Ms
              ? "over-budget"
              : distribution && allowedP95 !== null && distribution.p95 > allowedP95
                ? "regression"
                : "pass",
      });
    }
    if (baselineDoc && parsed.source?.base !== baselineDoc.source?.head)
      errors.push(
        `baseline head ${baselineDoc.source?.head ?? "missing"} does not match results source.base ${parsed.source?.base ?? "missing"}`,
      );
    if (baselineDoc) {
      const expected = new Set(parsed.expectedCases);
      for (const id of Object.keys(baselineDoc.results))
        if (!expected.has(id)) errors.push(`baseline has unexpected case: ${id}`);
    }
    if (budgetDoc) {
      const overBudget = [...rows].sort((a, b) => (b.p95 ?? -1) - (a.p95 ?? -1)).slice(0, budgetDoc.topN);
      for (const row of overBudget) {
        if (row.p95 !== null && row.p95 > budgetDoc.maxP95Ms && !row.fixingPr)
          errors.push(
            `${row.id}: p95 ${row.p95.toFixed(1)}ms exceeds ${budgetDoc.maxP95Ms.toFixed(1)}ms without an open fixing PR`,
          );
      }
      if (rows.some((row) => row.fixingPr))
        warnings.push("A fixing PR link is an owner-supplied exception; verify that it remains open.");
    }
  }
  return {
    ok: errors.length === 0,
    errors,
    warnings,
    rows: rows.sort((a, b) => (b.p95 ?? -1) - (a.p95 ?? -1)),
    head,
    base,
  };
}

function option(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

export async function main(args = process.argv.slice(2)): Promise<number> {
  const resultsPath = option(args, "--results");
  const baselinePath = option(args, "--baseline");
  const budgetPath = option(args, "--budget");
  const reportPath = option(args, "--report");
  if (!resultsPath || !baselinePath || !budgetPath)
    throw new Error(
      "usage: validate.ts --results FILE --baseline FILE --budget FILE [--expected-head SHA] [--pr NUMBER] [--report FILE]",
    );
  let evidence: unknown;
  let baseline: unknown;
  let budget: unknown;
  try {
    evidence = readJson(resultsPath);
  } catch (error) {
    evidence = {};
    baseline = {};
    budget = {};
    const result: ValidationResult = {
      ok: false,
      errors: [String(error)],
      warnings: [],
      rows: [],
      head: null,
      base: null,
    };
    const report = formatReport(result, option(args, "--pr"));
    if (reportPath) fs.writeFileSync(reportPath, report);
    console.error(report);
    return 1;
  }
  try {
    baseline = readJson(baselinePath);
  } catch (error) {
    baseline = {};
    console.warn(String(error));
  }
  try {
    budget = readJson(budgetPath);
  } catch (error) {
    budget = {};
    console.warn(String(error));
  }
  const result = validateEvidence(evidence, baseline, budget, { expectedHead: option(args, "--expected-head") });
  const report = formatReport(result, option(args, "--pr"));
  if (reportPath) fs.writeFileSync(reportPath, report);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, report);
  console.log(report);
  return result.ok ? 0 : 1;
}

if (process.argv[1] && /(?:^|\/)validate\.ts$/.test(process.argv[1])) {
  try {
    process.exitCode = await main();
  } catch (error) {
    console.error(`latency validator: ${String(error)}`);
    process.exitCode = 1;
  }
}
