import type { Attributes } from "@opentelemetry/api";
import {
  AlwaysOnSampler,
  ParentBasedSampler,
  SamplingDecision,
  TraceIdRatioBasedSampler,
  type Sampler,
} from "@opentelemetry/sdk-trace-base";

/**
 * Cloud VM API traffic is the traffic Axiom traces exist for: it is rare
 * (creates, base opens, attaches) and every attempt matters. Everything
 * else on the shared app (presence heartbeats, device polls, page loads)
 * arrives at thousands of spans per second and is only needed as a sample.
 * When the export endpoint was fixed on 2026-08-27 the unsampled firehose
 * measured ~4M spans per 15 minutes, almost all pg.query/fetch noise.
 */
export const VM_PRIORITY_PATH_PREFIX = "/api/vm";

/**
 * Coderouter is the second always-kept subsystem: its data plane (`/v1/*`,
 * the OpenCode proxy) and control plane (`/api/coderouter/*`) carry paid
 * model traffic at a few requests per minute, and every failed request is
 * something a customer will ask about by request id.
 */
export const PRIORITY_PATH_PREFIXES = [VM_PRIORITY_PATH_PREFIX, "/v1", "/api/coderouter"] as const;
const PRIORITY_SUBSYSTEMS: ReadonlySet<string> = new Set(["vm-cloud", "coderouter"]);

const PRIORITY_PATH_ATTRIBUTE_KEYS = ["http.route", "url.path", "http.target"] as const;

/**
 * Whether a root span, judged only by what is available at creation time,
 * belongs to Cloud VM work. Matches the request path when the runtime
 * provides it at start, the span name when it embeds the route, and the
 * `cmux.subsystem` attribute that `withApiRouteSpan` stamps on re-rooted
 * VM spans (the guaranteed signal: we control it).
 */
export function isVmPrioritySpan(spanName: string, attributes: Attributes): boolean {
  return isPrioritySpan(spanName, attributes);
}

export function isPrioritySpan(spanName: string, attributes: Attributes): boolean {
  const subsystem = attributes["cmux.subsystem"];
  if (typeof subsystem === "string" && PRIORITY_SUBSYSTEMS.has(subsystem)) return true;
  for (const key of PRIORITY_PATH_ATTRIBUTE_KEYS) {
    const value = attributes[key];
    if (typeof value === "string" && isPriorityPath(value)) return true;
  }
  return PRIORITY_PATH_PREFIXES.some(
    (prefix) => spanName.endsWith(` ${prefix}`) || spanName.includes(` ${prefix}/`),
  );
}

/** Path-segment-aware prefix match: /api/vm and /api/vm/..., never /api/vmstats. */
export function isVmPriorityPath(path: string): boolean {
  return hasPathPrefix(path, VM_PRIORITY_PATH_PREFIX);
}

/** Whether a request path belongs to an always-kept subsystem. */
export function isPriorityPath(path: string): boolean {
  return PRIORITY_PATH_PREFIXES.some((prefix) => hasPathPrefix(path, prefix));
}

function hasPathPrefix(path: string, prefix: string): boolean {
  if (!path.startsWith(prefix)) return false;
  const next = path.charAt(prefix.length);
  return next === "" || next === "/" || next === "?";
}

class VmPriorityRootSampler implements Sampler {
  constructor(private readonly base: Sampler) {}

  shouldSample(...args: Parameters<Sampler["shouldSample"]>): ReturnType<Sampler["shouldSample"]> {
    const [, , spanName, , attributes] = args;
    if (isPrioritySpan(spanName, attributes)) {
      return { decision: SamplingDecision.RECORD_AND_SAMPLED };
    }
    return this.base.shouldSample(...args);
  }

  toString(): string {
    return `VmPriorityRootSampler(${this.base.toString()})`;
  }
}

/**
 * The app-wide trace sampler: keep 100% of Cloud VM and coderouter traces, head-sample
 * everything else at `CMUX_OTEL_BASE_SAMPLE_RATIO` (default 2%). Children
 * follow their root's decision, so a kept VM trace keeps its pg/fetch/
 * provider child spans and a dropped page-load trace drops all of its own.
 */
export function buildCmuxTraceSampler(
  env: Record<string, string | undefined> = process.env,
): Sampler {
  const ratio = baseSampleRatio(env);
  const base = ratio >= 1 ? new AlwaysOnSampler() : new TraceIdRatioBasedSampler(ratio);
  const root = new VmPriorityRootSampler(base);
  // Remote parents come from untrusted clients: a caller can send a W3C
  // traceparent with the sampled flag set and would otherwise get the
  // ParentBased default (AlwaysOn), bypassing the ratio entirely. Ignore the
  // remote flag in both directions and make a fresh root decision instead.
  return new ParentBasedSampler({
    root,
    remoteParentSampled: root,
    remoteParentNotSampled: root,
  });
}

const DEFAULT_BASE_SAMPLE_RATIO = 0.02;

function baseSampleRatio(env: Record<string, string | undefined>): number {
  const raw = env.CMUX_OTEL_BASE_SAMPLE_RATIO?.trim();
  if (!raw) return DEFAULT_BASE_SAMPLE_RATIO;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) return DEFAULT_BASE_SAMPLE_RATIO;
  return parsed;
}
