// Shared statistics and Server-Timing helpers for the Cloud VM startup
// benchmarks (bench-vm-startup.mjs, bench-freestyle-floor.ts,
// bench-private-link.ts). Pure functions only, so
// tests/cloud-vm-bench-stats.test.ts covers them without a provider.

function round(value) {
  return Math.round(value * 10) / 10;
}

function finiteNumbers(values) {
  return (values ?? []).filter((value) => typeof value === "number" && Number.isFinite(value));
}

/** Nearest-rank percentile of `values` at `fraction` (0..1); null when empty. */
export function percentile(values, fraction) {
  const sorted = finiteNumbers(values).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const rank = Math.ceil(fraction * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

/** Count, min, p50, p90, p95, max and mean of a sample, rounded to 0.1. */
export function summarize(values) {
  const finite = finiteNumbers(values);
  if (finite.length === 0) return { n: 0 };
  const sum = finite.reduce((total, value) => total + value, 0);
  return {
    n: finite.length,
    min: round(Math.min(...finite)),
    p50: round(percentile(finite, 0.5)),
    p90: round(percentile(finite, 0.9)),
    p95: round(percentile(finite, 0.95)),
    max: round(Math.max(...finite)),
    mean: round(sum / finite.length),
  };
}

/**
 * `Server-Timing: auth;dur=0.23, provider_create;dur=1205.91` → `{auth: 0.23, …}`.
 * Metrics without a numeric `dur` are skipped; a missing header yields `{}`.
 */
export function parseServerTiming(header) {
  const stages = {};
  if (typeof header !== "string" || header.trim() === "") return stages;
  for (const metric of header.split(",")) {
    const parts = metric.split(";").map((part) => part.trim()).filter((part) => part.length > 0);
    const name = parts[0];
    if (!name) continue;
    for (const param of parts.slice(1)) {
      const separator = param.indexOf("=");
      if (separator === -1) continue;
      if (param.slice(0, separator).trim().toLowerCase() !== "dur") continue;
      const value = Number(param.slice(separator + 1).trim().replace(/^"|"$/g, ""));
      if (Number.isFinite(value)) stages[name] = value;
    }
  }
  return stages;
}

/** Per-stage summaries across many parsed Server-Timing maps. */
export function summarizeStages(stageMaps) {
  const byStage = {};
  for (const stages of stageMaps ?? []) {
    for (const [name, value] of Object.entries(stages ?? {})) {
      const samples = byStage[name] ?? [];
      samples.push(value);
      byStage[name] = samples;
    }
  }
  return Object.fromEntries(Object.entries(byStage).map(([name, values]) => [name, summarize(values)]));
}

/** Summaries of the numeric `fields` across trial records. */
export function summarizeFields(records, fields) {
  return Object.fromEntries(
    fields.map((field) => [field, summarize((records ?? []).map((record) => record?.[field]))]),
  );
}

/** Milliseconds since a `performance.now()` mark, rounded to 0.1. */
export function elapsedMs(startedAt) {
  return round(performance.now() - startedAt);
}

/** A fixed-width text table of `{name: summary}` for terminal output. */
export function formatSummary(summaries) {
  const rows = [["stage", "n", "p50", "p90", "p95", "max"]];
  for (const [name, summary] of Object.entries(summaries ?? {})) {
    if (!summary || summary.n === 0) {
      rows.push([name, "0", "-", "-", "-", "-"]);
      continue;
    }
    rows.push([name, String(summary.n), String(summary.p50), String(summary.p90), String(summary.p95), String(summary.max)]);
  }
  const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
  return rows.map((row) => row.map((cell, column) => cell.padEnd(widths[column])).join("  ").trimEnd()).join("\n");
}
