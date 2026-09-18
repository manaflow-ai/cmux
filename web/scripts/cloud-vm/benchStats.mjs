// Shared statistics and Server-Timing helpers for the Cloud VM startup
// benchmarks (bench-vm-startup.mjs, bench-freestyle-floor.ts,
// bench-private-link.ts). Pure functions only, so
// tests/cloud-vm-bench-stats.test.ts covers them without a provider.
import { createHash } from "node:crypto";

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

/**
 * The provider slug of a user's owner network, `cmux-net-<sha256 prefix>`.
 * Mirrors `networkSlugForUser` in services/vms/privateNetwork.ts (no secret
 * enters the hash); tests/cloud-vm-bench-stats.test.ts pins the equality so
 * the benchmark's cleanup cannot drift from the application's derivation.
 */
export function ownerNetworkSlug(userId) {
  return `cmux-net-${createHash("sha256").update("cmux:network:").update(userId).digest("hex").slice(0, 32)}`;
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

/**
 * The provider credentials in either form the runtime's client accepts
 * (services/vms/drivers/freestyle.ts): an API key, or a Stack access token
 * with a team id, plus the optional API base URL; null when neither form is
 * complete. `env` is the environment to read, so a caller can overlay a
 * deployment's pulled values on the process environment.
 * @param {Record<string, string | undefined>} [env]
 */
export function providerCredentialsFromEnv(env = process.env) {
  const value = (key) => (typeof env[key] === "string" ? env[key].trim() : "");
  const baseUrl = value("FREESTYLE_API_URL") || undefined;
  const apiKey = value("FREESTYLE_API_KEY");
  if (apiKey) return { apiKey, baseUrl };
  const stackAccessToken = value("FREESTYLE_STACK_ACCESS_TOKEN");
  const teamId = value("FREESTYLE_TEAM_ID");
  if (stackAccessToken && teamId) return { stackAccessToken, teamId, baseUrl };
  return null;
}

/**
 * A `fetch` for the provider SDK that bounds every request and ends the
 * SDK's polling of a backgrounded request: the SDK follows a 202 by polling
 * its result URL with a timer it never cancels, so a request the platform
 * never finishes would otherwise be tracked forever. Each fetch carries a
 * timeout, and a background request still being polled `pollDeadlineMs`
 * after its first poll is refused, which makes the SDK give up (after five
 * consecutive failures) and settles the request. Settling is not
 * completion: the platform's own work continues, so every abandoned
 * background request is recorded in `abandoned` (shared between clients
 * when a caller passes one set), and a caller must report its cleanup as
 * unresolved while that set is non-empty. `now` and `fetchImpl` are
 * injectable for tests.
 */
export function pollBoundedFetch({ fetchTimeoutMs, pollDeadlineMs, abandoned = new Set(), now = Date.now, fetchImpl = globalThis.fetch }) {
  const firstPollAt = new Map();
  const fetch = (input, init) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/background-requests/")) {
      const first = firstPollAt.get(url) ?? now();
      firstPollAt.set(url, first);
      if (now() - first > pollDeadlineMs) {
        abandoned.add(url);
        return Promise.reject(new Error(`provider background request exceeded ${pollDeadlineMs} ms`));
      }
    }
    return fetchImpl(input, { ...(init ?? {}), signal: AbortSignal.timeout(fetchTimeoutMs) });
  };
  return { fetch, abandoned };
}
