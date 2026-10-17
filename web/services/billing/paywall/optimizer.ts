// The paywall optimizer: reads per-variant exposures and conversions for one
// pre-registered experiment from PostHog, computes a Beta-Bernoulli
// Thompson-sampling allocation under the experiment's policy, checks for a
// sample-ratio mismatch, and (unless it is a dry run) writes the new traffic
// split to the PostHog flag and every change to the experiment change log.
// Generic over experiments.ts; EXPERIMENTS.md is the human-readable contract.

import { createHash } from "node:crypto";

import type { ExperimentDefinition, ExperimentMetric } from "./experiments";
import type { PaywallChange, PaywallExperimentLog, PaywallRun } from "./store";

// PostHog access (personal API key; read the project, write one flag).

export type PostHogFlag = {
  readonly id: number;
  readonly key: string;
  readonly active: boolean;
  readonly filters: Record<string, unknown>;
  readonly variants: readonly { readonly key: string; readonly name?: string; readonly rolloutPercentage: number }[];
  readonly payloads: Readonly<Record<string, unknown>>;
};

export type PostHogApi = {
  readonly query: (hogql: string) => Promise<readonly (readonly unknown[])[]>;
  readonly flag: (key: string) => Promise<PostHogFlag | null>;
  readonly setVariantRollouts: (flag: PostHogFlag, rollouts: Readonly<Record<string, number>>) => Promise<void>;
};

export function postHogApi(input: {
  readonly personalApiKey: string;
  readonly projectId: string;
  readonly host?: string;
  readonly fetch?: typeof fetch;
}): PostHogApi {
  const host = (input.host ?? "https://us.posthog.com").replace(/\/$/, "");
  const fetchImpl = input.fetch ?? fetch;
  const base = `${host}/api/projects/${encodeURIComponent(input.projectId)}`;
  const request = async (path: string, init: RequestInit = {}): Promise<unknown> => {
    const response = await fetchImpl(`${base}${path}`, {
      ...init,
      headers: { authorization: `Bearer ${input.personalApiKey}`, "content-type": "application/json" },
      signal: AbortSignal.timeout(120_000),
    });
    if (!response.ok) {
      throw new Error(`PostHog ${init.method ?? "GET"} ${path} failed with ${response.status}: ${(await response.text()).slice(0, 300)}`);
    }
    return response.json();
  };
  return {
    query: async (hogql) => {
      const body = await request("/query/", {
        method: "POST",
        body: JSON.stringify({ query: { kind: "HogQLQuery", query: hogql } }),
      }) as { results?: unknown[][] };
      return body.results ?? [];
    },
    flag: async (key) => {
      // `search` narrows by substring; the exact key match is ours. Follow
      // pagination so a project with many similar keys cannot hide the flag.
      let path: string | null = `/feature_flags/?search=${encodeURIComponent(key)}&limit=100`;
      for (let page = 0; path && page < 20; page += 1) {
        const body = await request(path) as { results?: Record<string, unknown>[]; next?: string | null };
        const raw = (body.results ?? []).find((flag) => flag.key === key && flag.deleted !== true);
        if (raw) return parsePostHogFlag(raw);
        path = body.next ? nextPath(body.next, base) : null;
      }
      return null;
    },
    setVariantRollouts: async (flag, rollouts) => {
      const multivariate = (flag.filters.multivariate ?? {}) as { variants?: Record<string, unknown>[] };
      const variants = (multivariate.variants ?? []).map((variant) => ({
        ...variant,
        rollout_percentage: rollouts[String(variant.key)] ?? 0,
      }));
      await request(`/feature_flags/${flag.id}/`, {
        method: "PATCH",
        body: JSON.stringify({ filters: { ...flag.filters, multivariate: { ...multivariate, variants } } }),
      });
    },
  };
}

/** The `next` URL of a PostHog list page as a path under this project, or null if it points elsewhere. */
function nextPath(next: string, base: string): string | null {
  return next.startsWith(base) ? next.slice(base.length) : null;
}

export function parsePostHogFlag(raw: Record<string, unknown>): PostHogFlag {
  const filters = (raw.filters ?? {}) as Record<string, unknown>;
  const multivariate = (filters.multivariate ?? {}) as { variants?: Record<string, unknown>[] };
  const payloads = (filters.payloads ?? {}) as Record<string, unknown>;
  return {
    id: Number(raw.id),
    key: String(raw.key),
    active: raw.active === true,
    filters,
    variants: (multivariate.variants ?? []).map((variant) => ({
      key: String(variant.key),
      name: typeof variant.name === "string" ? variant.name : undefined,
      rolloutPercentage: Number(variant.rollout_percentage ?? 0),
    })),
    payloads,
  };
}

// Statistics.

export type VariantStats = {
  readonly variant: string;
  /** People whose first exposure was to this variant. */
  readonly exposures: number;
  /** Of those, people with a primary-metric event after their first exposure. */
  readonly conversions: number;
  /**
   * Exposed people assigned since the last allocation change (for the SRM test).
   * Sticky first exposures are left out: an earlier exposure was lost, so the
   * user was assigned under an older split.
   */
  readonly exposuresSinceChange: number;
  readonly secondary: Readonly<Record<string, number>>;
  readonly guardrails: Readonly<Record<string, number>>;
};

const DATE = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)?$/;

function hogqlTimestamp(value: string): string {
  if (!DATE.test(value)) throw new Error(`Invalid timestamp ${value}`);
  // Timestamps are UTC; without the zone HogQL reads them in the project's time zone.
  return `toDateTime('${value.replace("T", " ").replace(/\.\d+Z?$|Z$/, "")}', 'UTC')`;
}

function hogqlString(value: string): string {
  if (!/^[A-Za-z0-9_.$-]+$/.test(value)) throw new Error(`Invalid identifier ${value}`);
  return `'${value}'`;
}

/** The client's view event may be stamped slightly before the assignment record. */
const VIEW_CLOCK_SKEW_SECONDS = 300;

/**
 * Each exposed person once: the assigned variant from the first
 * `paywall_assigned` (iOS: sent by the server; web: sent by the browser for
 * the proxy cookie's arm; assignment is sticky) joined to the person's first
 * exposure event after it. `first_at` is the exposure time. A person who was assigned but never
 * saw the paywall is not exposed.
 */
function exposureSubquery(definition: ExperimentDefinition): string {
  return `SELECT a.person_id AS person_id, a.variant AS variant, a.first_sticky AS first_sticky, a.assigned_at AS assigned_at,
      min(v.timestamp) AS first_at
    FROM (
      SELECT person_id, argMin(properties.paywall_variant, timestamp) AS variant, min(timestamp) AS assigned_at,
        argMin(coalesce(toString(properties.paywall_sticky), ''), timestamp) AS first_sticky
      FROM events
      WHERE event = 'paywall_assigned'
        AND properties.paywall_experiment = ${hogqlString(definition.key)}
        AND timestamp >= ${hogqlTimestamp(definition.startDate)}
        AND (${definition.assignmentWhere})
      GROUP BY person_id
    ) AS a
    INNER JOIN (
      SELECT person_id, timestamp FROM events
      WHERE event = ${hogqlString(definition.exposureEvent)}
        AND properties.paywall_experiment = ${hogqlString(definition.key)}
        AND timestamp >= ${hogqlTimestamp(definition.startDate)}
        AND (${definition.exposureWhere})
    ) AS v ON a.person_id = v.person_id
    WHERE v.timestamp >= a.assigned_at - toIntervalSecond(${VIEW_CLOCK_SKEW_SECONDS})
    GROUP BY a.person_id, a.variant, a.first_sticky, a.assigned_at`;
}

/** People whose exposure event named a different arm than the server assigned (an app bug if not 0). */
export async function clientVariantMismatches(api: PostHogApi, definition: ExperimentDefinition): Promise<number> {
  const rows = await api.query(`SELECT count(DISTINCT e.person_id)
    FROM (${exposureSubquery(definition)}) AS e
    INNER JOIN (
      SELECT person_id, coalesce(toString(properties.paywall_variant), '') AS client_variant, timestamp FROM events
      WHERE event = ${hogqlString(definition.exposureEvent)}
        AND properties.paywall_experiment = ${hogqlString(definition.key)}
        AND timestamp >= ${hogqlTimestamp(definition.startDate)}
    ) AS c ON e.person_id = c.person_id
    WHERE c.timestamp >= e.assigned_at - toIntervalSecond(${VIEW_CLOCK_SKEW_SECONDS}) AND c.client_variant != e.variant`);
  return Number(rows[0]?.[0] ?? 0);
}

function metricQuery(definition: ExperimentDefinition, metric: ExperimentMetric, since: string): string {
  return `SELECT e.variant, count() AS exposed, countIf(m.last_at >= e.first_at) AS converted,
      countIf(e.assigned_at >= ${hogqlTimestamp(since)} AND e.first_sticky NOT IN ('true', '1')) AS exposed_since
    FROM (${exposureSubquery(definition)}) AS e
    LEFT JOIN (
      SELECT person_id, max(timestamp) AS last_at FROM events
      WHERE event = ${hogqlString(metric.event)}
        AND timestamp >= ${hogqlTimestamp(definition.startDate)}
        AND (${metric.where})
      GROUP BY person_id
    ) AS m ON e.person_id = m.person_id
    GROUP BY e.variant
    LIMIT 1000`;
}

type MetricRow = { exposed: number; converted: number; exposedSince: number };

async function metricCounts(
  api: PostHogApi,
  definition: ExperimentDefinition,
  metric: ExperimentMetric,
  since: string,
): Promise<Map<string, MetricRow>> {
  const rows = await api.query(metricQuery(definition, metric, since));
  const counts = new Map<string, MetricRow>();
  for (const row of rows) {
    counts.set(String(row[0]), { exposed: Number(row[1]), converted: Number(row[2]), exposedSince: Number(row[3]) });
  }
  return counts;
}

export async function fetchVariantStats(
  api: PostHogApi,
  definition: ExperimentDefinition,
  variants: readonly string[],
  allocationSince: string,
): Promise<VariantStats[]> {
  const primary = await metricCounts(api, definition, definition.primary, allocationSince);
  const secondary = await Promise.all(definition.secondary.map(async (metric) => [metric.key, await metricCounts(api, definition, metric, allocationSince)] as const));
  const guardrails = await Promise.all(definition.guardrails.map(async (metric) => [metric.key, await metricCounts(api, definition, metric, allocationSince)] as const));
  const names = new Set([...variants, ...primary.keys()]);
  return [...names].map((variant) => ({
    variant,
    exposures: primary.get(variant)?.exposed ?? 0,
    conversions: primary.get(variant)?.converted ?? 0,
    exposuresSinceChange: primary.get(variant)?.exposedSince ?? 0,
    secondary: Object.fromEntries(secondary.map(([key, counts]) => [key, counts.get(variant)?.converted ?? 0])),
    guardrails: Object.fromEntries(guardrails.map(([key, counts]) => [key, counts.get(variant)?.converted ?? 0])),
  }));
}

/** Seeded PRNG (mulberry32), so a run's decision is reproducible from its seed. */
export function seededRandom(seed: string): () => number {
  let state = createHash("sha256").update(seed).digest().readUInt32LE(0);
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function normal(random: () => number): number {
  const u = Math.max(random(), Number.EPSILON);
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * random());
}

/** Marsaglia-Tsang gamma sampler for shape >= 1. */
function gamma(shape: number, random: () => number): number {
  const d = shape - 1 / 3;
  const c = 1 / Math.sqrt(9 * d);
  for (;;) {
    let x: number;
    let v: number;
    do {
      x = normal(random);
      v = 1 + c * x;
    } while (v <= 0);
    v = v * v * v;
    const u = random();
    if (u < 1 - 0.0331 * x ** 4 || Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) return d * v;
  }
}

function beta(alpha: number, betaShape: number, random: () => number): number {
  const x = gamma(alpha, random);
  return x / (x + gamma(betaShape, random));
}

/** P(variant has the highest conversion rate) under Beta(1 + conversions, 1 + misses) posteriors. */
export function probabilityBest(stats: readonly VariantStats[], random: () => number, draws = 20_000): Record<string, number> {
  const wins: Record<string, number> = Object.fromEntries(stats.map((stat) => [stat.variant, 0]));
  for (let draw = 0; draw < draws; draw += 1) {
    let best = "";
    let bestValue = -1;
    for (const stat of stats) {
      const value = beta(1 + stat.conversions, 1 + Math.max(0, stat.exposures - stat.conversions), random);
      if (value > bestValue) {
        bestValue = value;
        best = stat.variant;
      }
    }
    wins[best] = (wins[best] ?? 0) + 1;
  }
  return Object.fromEntries(Object.entries(wins).map(([variant, count]) => [variant, count / draws]));
}

function logGamma(x: number): number {
  const coefficients = [76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5];
  let y = x;
  const tmp = x + 5.5 - (x + 0.5) * Math.log(x + 5.5);
  let series = 1.000000000190015;
  for (const coefficient of coefficients) series += coefficient / ++y;
  return -tmp + Math.log((2.5066282746310005 * series) / x);
}

/** Regularized upper incomplete gamma Q(a, x). */
function upperGammaRegularized(a: number, x: number): number {
  if (x <= 0) return 1;
  if (x < a + 1) {
    let sum = 1 / a;
    let term = sum;
    for (let n = 1; n < 500; n += 1) {
      term *= x / (a + n);
      sum += term;
      if (Math.abs(term) < Math.abs(sum) * 1e-14) break;
    }
    return 1 - sum * Math.exp(-x + a * Math.log(x) - logGamma(a));
  }
  let b = x + 1 - a;
  let c = 1 / 1e-300;
  let d = 1 / b;
  let h = d;
  for (let i = 1; i < 500; i += 1) {
    const an = -i * (i - a);
    b += 2;
    d = an * d + b;
    if (Math.abs(d) < 1e-300) d = 1e-300;
    c = b + an / c;
    if (Math.abs(c) < 1e-300) c = 1e-300;
    d = 1 / d;
    const delta = d * c;
    h *= delta;
    if (Math.abs(delta - 1) < 1e-14) break;
  }
  return Math.exp(-x + a * Math.log(x) - logGamma(a)) * h;
}

export type SrmResult =
  | { readonly tested: false; readonly reason: string }
  | { readonly tested: true; readonly chiSquare: number; readonly pValue: number; readonly mismatch: boolean };

/**
 * Chi-square goodness of fit of first exposures since the last allocation
 * change against that allocation. Not tested until every live variant
 * expects at least 5 people.
 */
export function sampleRatioMismatch(
  stats: readonly VariantStats[],
  rollouts: Readonly<Record<string, number>>,
  alpha: number,
): SrmResult {
  const live = stats.filter((stat) => (rollouts[stat.variant] ?? 0) > 0);
  const stray = stats.filter((stat) => (rollouts[stat.variant] ?? 0) === 0).reduce((sum, stat) => sum + stat.exposuresSinceChange, 0);
  const total = live.reduce((sum, stat) => sum + stat.exposuresSinceChange, 0) + stray;
  const share = live.reduce((sum, stat) => sum + (rollouts[stat.variant] ?? 0), 0);
  if (live.length < 2 || share === 0) return { tested: false, reason: "fewer than two live variants" };
  if (stray > 0) {
    // First exposures to a variant at 0% cannot happen through the flag: the
    // assignment path is broken, whatever the arms' counts say.
    return { tested: true, chiSquare: Number.POSITIVE_INFINITY, pValue: 0, mismatch: true };
  }
  const expected = live.map((stat) => (total * (rollouts[stat.variant] ?? 0)) / share);
  if (expected.some((value) => value < 5)) return { tested: false, reason: `too few exposures since the last allocation change (${total})` };
  const chiSquare = live.reduce((sum, stat, index) => sum + (stat.exposuresSinceChange - expected[index]!) ** 2 / expected[index]!, 0);
  const pValue = upperGammaRegularized((live.length - 1) / 2, chiSquare / 2);
  return { tested: true, chiSquare, pValue, mismatch: pValue < alpha };
}

/** Integer percentages summing to 100 by largest remainder; live variants keep at least 1%. */
export function integerRollouts(weights: Readonly<Record<string, number>>): Record<string, number> {
  const entries = Object.entries(weights).filter(([, weight]) => weight > 0);
  const total = entries.reduce((sum, [, weight]) => sum + weight, 0);
  if (entries.length === 0 || total <= 0) return {};
  const exact = entries.map(([variant, weight]) => [variant, Math.max(1, (weight / total) * 100)] as const);
  const scale = 100 / exact.reduce((sum, [, value]) => sum + value, 0);
  const scaled = exact.map(([variant, value]) => [variant, value * scale] as const);
  const result: Record<string, number> = Object.fromEntries(scaled.map(([variant, value]) => [variant, Math.max(1, Math.floor(value))]));
  let remaining = 100 - Object.values(result).reduce((sum, value) => sum + value, 0);
  const order = [...scaled].sort((left, right) => (right[1] - Math.floor(right[1])) - (left[1] - Math.floor(left[1])));
  for (let index = 0; remaining !== 0 && order.length > 0; index = (index + 1) % order.length) {
    const variant = order[index]![0];
    if (remaining > 0) {
      result[variant]! += 1;
      remaining -= 1;
    } else if (result[variant]! > 1) {
      result[variant]! -= 1;
      remaining += 1;
    }
  }
  return result;
}

export type OptimizerDecision = {
  readonly current: Readonly<Record<string, number>>;
  readonly target: Readonly<Record<string, number>>;
  readonly probabilityBest: Readonly<Record<string, number>>;
  readonly retire: readonly string[];
  /** Queued variants this run makes live (live-arm cap). */
  readonly promote: readonly string[];
  readonly srm: SrmResult;
  readonly halted: boolean;
  readonly reasons: readonly string[];
  readonly changed: boolean;
};

/** Thompson-sampling allocation under the policy, with the control floor applied. */
function thompsonTarget(
  definition: ExperimentDefinition,
  live: readonly VariantStats[],
  pBest: Readonly<Record<string, number>>,
): Record<string, number> {
  const { controlFloor } = definition.policy;
  const control = definition.controlVariant;
  const others = live.filter((stat) => stat.variant !== control);
  const otherTotal = others.reduce((sum, stat) => sum + (pBest[stat.variant] ?? 0), 0);
  const controlShare = Math.max(controlFloor, pBest[control] ?? 0);
  const weights: Record<string, number> = { [control]: controlShare };
  for (const stat of others) {
    weights[stat.variant] = otherTotal > 0
      ? ((pBest[stat.variant] ?? 0) / otherTotal) * (1 - controlShare)
      : (1 - controlShare) / others.length;
  }
  // Keep at least 1% on every live variant: dropping to 0 is retirement, which has its own rule.
  for (const stat of live) weights[stat.variant] = Math.max(weights[stat.variant] ?? 0, 0.01);
  const rollouts = integerRollouts(weights);
  // Rounding must not take control under its floor.
  const floor = Math.ceil(controlFloor * 100);
  if ((rollouts[control] ?? 0) < floor) {
    const largest = Object.entries(rollouts).filter(([variant]) => variant !== control).sort((a, b) => b[1] - a[1])[0];
    if (largest) {
      const move = floor - (rollouts[control] ?? 0);
      rollouts[largest[0]] = largest[1] - move;
      rollouts[control] = floor;
    }
  }
  return rollouts;
}

/** Variants to retire now: challengers with enough exposures and almost no chance of being best. */
function retirements(definition: ExperimentDefinition, live: readonly VariantStats[], pBest: Readonly<Record<string, number>>, reasons: string[]): string[] {
  const policy = definition.policy;
  const retire = live
    .filter((stat) => stat.variant !== definition.controlVariant
      && stat.exposures >= policy.retireMinExposures
      && (pBest[stat.variant] ?? 0) < policy.retireBelowProbability)
    .map((stat) => stat.variant);
  for (const variant of retire) {
    reasons.push(`retire ${variant}: P(best)=${(pBest[variant] ?? 0).toFixed(4)} < ${policy.retireBelowProbability} after ${live.find((stat) => stat.variant === variant)?.exposures} exposures`);
  }
  return retire;
}

/** Queued variants (0%, never retired) promoted, in flag order, to fill the live-arm cap. */
function promotions(
  definition: ExperimentDefinition,
  stats: readonly VariantStats[],
  liveCount: number,
  promotable: readonly string[],
  reasons: string[],
): VariantStats[] {
  const room = Math.max(0, definition.policy.maxLiveArms - liveCount);
  const queued = promotable
    .slice(0, room)
    .map((variant) => stats.find((stat) => stat.variant === variant)
      ?? { variant, exposures: 0, conversions: 0, exposuresSinceChange: 0, secondary: {}, guardrails: {} });
  for (const stat of queued) reasons.push(`promote ${stat.variant}: fewer than ${definition.policy.maxLiveArms} live arms`);
  return queued;
}

/** The split for the arms that stay or become live; every other variant goes to 0%. */
function armSplit(
  definition: ExperimentDefinition,
  arms: readonly VariantStats[],
  pBest: Readonly<Record<string, number>>,
  reasons: string[],
): Record<string, number> {
  const policy = definition.policy;
  const short = arms.filter((stat) => stat.exposures < policy.minExposuresPerVariant);
  if (short.length > 0) {
    reasons.push(`hold equal split: ${short.map((stat) => `${stat.variant} has ${stat.exposures}/${policy.minExposuresPerVariant} exposures`).join(", ")}`);
    return integerRollouts(Object.fromEntries(arms.map((stat) => [stat.variant, 1])));
  }
  reasons.push(`Thompson sampling: traffic follows P(best), control floor ${Math.round(policy.controlFloor * 100)}%`);
  return thompsonTarget(definition, arms, pBest);
}

export function decideAllocation(
  definition: ExperimentDefinition,
  flag: Pick<PostHogFlag, "variants">,
  stats: readonly VariantStats[],
  random: () => number,
  /** Queued variants that may go live now, in queue order (see promotableVariants). */
  promotable: readonly string[] = [],
): OptimizerDecision {
  const policy = definition.policy;
  const current = Object.fromEntries(flag.variants.map((variant) => [variant.key, variant.rolloutPercentage]));
  const known = new Set(flag.variants.map((variant) => variant.key));
  const live = stats.filter((stat) => known.has(stat.variant) && (current[stat.variant] ?? 0) > 0);
  const reasons: string[] = [];
  const srm = sampleRatioMismatch(stats.filter((stat) => known.has(stat.variant)), current, policy.srmAlpha);
  const pBest = live.length > 0 ? probabilityBest(live, random) : {};
  const hold = (reason: string, halted = false): OptimizerDecision => ({
    current, target: current, probabilityBest: pBest, retire: [], promote: [], srm, halted, reasons: [...reasons, reason], changed: false,
  });
  if (srm.tested && srm.mismatch) {
    return hold(`halted: sample ratio mismatch (chi-square ${srm.chiSquare.toFixed(2)}, p=${srm.pValue.toExponential(2)} < ${policy.srmAlpha}); no traffic change until it is explained`, true);
  }
  if (!live.some((stat) => stat.variant === definition.controlVariant)) {
    return hold("halted: control is not live in the flag; restore it before the optimizer moves traffic", true);
  }
  // Retirement needs every live arm past the minimum sample, like any traffic move.
  const ready = live.every((stat) => stat.exposures >= policy.minExposuresPerVariant);
  const retire = ready ? retirements(definition, live, pBest, reasons) : [];
  const remaining = live.filter((stat) => !retire.includes(stat.variant));
  const promoted = promotions(definition, stats, remaining.length, promotable, reasons);
  const split = armSplit(definition, [...remaining, ...promoted], pBest, reasons);
  const target: Record<string, number> = Object.fromEntries(flag.variants.map((variant) => [variant.key, split[variant.key] ?? 0]));
  const changed = Object.keys(target).some((variant) => target[variant] !== current[variant]);
  if (!changed) reasons.push("allocation unchanged");
  return { current, target, probabilityBest: pBest, retire, promote: promoted.map((stat) => stat.variant), srm, halted: false, reasons, changed };
}

// One optimizer run.

export type VariantSnapshot = {
  readonly variant: string;
  readonly name: string | null;
  /** `queued`: at 0% and never retired, waiting for a live slot. */
  readonly status: "live" | "retired" | "queued";
  readonly rolloutBefore: number;
  readonly rolloutAfter: number;
  readonly exposures: number;
  readonly conversions: number;
  readonly probabilityBest: number | null;
  readonly secondary: Readonly<Record<string, number>>;
  readonly guardrails: Readonly<Record<string, number>>;
  readonly payload: unknown;
  readonly payloadHash: string | null;
  readonly payloadErrors: readonly string[];
};

export type OptimizerSnapshot = {
  readonly experiment: string;
  readonly platform: string;
  readonly flagFound: boolean;
  readonly dryRun: boolean;
  /** True when this run wrote its target split to the flag. */
  readonly allocationApplied: boolean;
  readonly allocationSince: string;
  /** Exposed people whose app reported another arm than the server assigned. */
  readonly clientVariantMismatches: number;
  readonly decision: OptimizerDecision;
  readonly variants: readonly VariantSnapshot[];
};

export type OptimizerRunResult = {
  readonly snapshot: OptimizerSnapshot;
  readonly changes: readonly PaywallChange[];
  readonly report: string;
  /** Set when the flag write failed and the run fell back to observe mode. */
  readonly writeFailure: string | null;
};

function parsedPayload(payload: unknown): unknown {
  if (typeof payload !== "string") return payload ?? null;
  try {
    return JSON.parse(payload);
  } catch {
    return payload;
  }
}

function payloadHash(payload: unknown): string | null {
  if (payload === null || payload === undefined) return null;
  return createHash("sha256").update(JSON.stringify(payload)).digest("hex").slice(0, 16);
}

function previousVariants(run: PaywallRun | null): Map<string, { status: string; payloadHash: string | null }> {
  const snapshot = run?.snapshot as Partial<OptimizerSnapshot> | undefined;
  return new Map((snapshot?.variants ?? []).map((variant) => [variant.variant, { status: variant.status, payloadHash: variant.payloadHash }]));
}

function changeLog(
  definition: ExperimentDefinition,
  variants: readonly VariantSnapshot[],
  decision: OptimizerDecision,
  previous: PaywallRun | null,
  actor: string,
): PaywallChange[] {
  const before = previousVariants(previous);
  const base = { experiment: definition.key, actor };
  const changes: PaywallChange[] = [];
  for (const variant of variants) {
    const prior = before.get(variant.variant);
    if (!prior) {
      changes.push({ ...base, kind: "variant_created", variant: variant.variant, reason: "first seen in the flag", details: { name: variant.name, payload: variant.payload, rollout: variant.rolloutBefore } });
    } else if (prior.payloadHash !== variant.payloadHash) {
      changes.push({ ...base, kind: "copy_changed", variant: variant.variant, reason: "flag payload changed", details: { payload: variant.payload } });
    }
    if (variant.payloadErrors.length > 0 && (!prior || prior.payloadHash !== variant.payloadHash)) {
      changes.push({ ...base, kind: "payload_invalid", variant: variant.variant, reason: "payload fails the copy validator; control is served instead", details: { errors: variant.payloadErrors } });
    }
  }
  for (const variant of decision.promote) {
    changes.push({ ...base, kind: "variant_promoted", variant, reason: decision.reasons.find((reason) => reason.startsWith(`promote ${variant}`)) ?? "promoted", details: null });
  }
  for (const variant of decision.retire) {
    changes.push({ ...base, kind: "variant_retired", variant, reason: decision.reasons.find((reason) => reason.startsWith(`retire ${variant}`)) ?? "retired", details: { probabilityBest: decision.probabilityBest[variant] ?? null } });
  }
  if (decision.halted && decision.srm.tested) {
    changes.push({ ...base, kind: "srm_halt", variant: null, reason: decision.reasons.at(-1) ?? "sample ratio mismatch", details: { chiSquare: decision.srm.chiSquare, pValue: decision.srm.pValue } });
  }
  if (decision.changed) {
    changes.push({ ...base, kind: "allocation_changed", variant: null, reason: decision.reasons.join("; "), details: { from: decision.current, to: decision.target } });
  }
  return changes;
}

function percent(numerator: number, denominator: number): string {
  return denominator > 0 ? `${((numerator / denominator) * 100).toFixed(1)}%` : "n/a";
}

/** Where each platform's `paywall_assigned` comes from, for the report. */
const ASSIGNMENT_SOURCE: Readonly<Record<ExperimentDefinition["platform"], string>> = {
  ios: "the server's assignment (`paywall_assigned` sent by the server)",
  web: "the proxy cookie's assignment (`paywall_assigned` sent by the browser)",
};

export function optimizerReport(definition: ExperimentDefinition, snapshot: OptimizerSnapshot, changes: readonly PaywallChange[], now: Date): string {
  const { decision } = snapshot;
  const lines = [
    `# ${definition.key} optimizer report, ${now.toISOString().slice(0, 10)}`,
    "",
    `Platform: ${definition.platform} (never pooled with other platforms). Flag: ${definition.flagKey}${snapshot.flagFound ? "" : " (NOT FOUND: using the seed definition)"}. Mode: ${snapshot.dryRun ? "dry run, nothing written" : "live"}.`,
    `Primary metric: ${definition.primary.label}, per exposed person after first exposure. Exposure: first \`${definition.exposureEvent}\` after ${ASSIGNMENT_SOURCE[definition.platform]}, in that assigned arm; since ${definition.startDate}, excluding internal, synthetic and non-production.`,
    `People whose app reported a different arm than the server assigned: ${snapshot.clientVariantMismatches}.`,
    "",
    `| Variant | Status | Traffic now | Traffic next | Exposed | Converted | Rate | P(best) | ${definition.secondary.map((metric) => metric.key).join(" | ")} | ${definition.guardrails.map((metric) => metric.key).join(" | ")} |`,
    `|---|---|---|---|---|---|---|---|${definition.secondary.map(() => "---|").join("")}${definition.guardrails.map(() => "---|").join("")}`,
    ...snapshot.variants.map((variant) => `| ${variant.variant} | ${variant.status}${variant.payloadErrors.length ? " (invalid copy)" : ""} | ${variant.rolloutBefore}% | ${variant.rolloutAfter}% | ${variant.exposures} | ${variant.conversions} | ${percent(variant.conversions, variant.exposures)} | ${variant.probabilityBest === null ? "n/a" : variant.probabilityBest.toFixed(3)} | ${definition.secondary.map((metric) => `${variant.secondary[metric.key] ?? 0} (${percent(variant.secondary[metric.key] ?? 0, variant.exposures)})`).join(" | ")} | ${definition.guardrails.map((metric) => String(variant.guardrails[metric.key] ?? 0)).join(" | ")} |`),
    "",
    `Sample ratio check (first exposures since ${snapshot.allocationSince}): ${decision.srm.tested ? `chi-square ${decision.srm.chiSquare.toFixed(2)}, p=${decision.srm.pValue.toExponential(2)}${decision.srm.mismatch ? " MISMATCH" : ""}` : `not tested, ${decision.srm.reason}`}.`,
    "",
    "Decision:",
    ...decision.reasons.map((reason) => `- ${reason}`),
    "",
    changes.length > 0 ? "Changes logged:" : "No changes logged.",
    ...changes.map((change) => `- ${change.kind}${change.variant ? ` ${change.variant}` : ""}: ${change.reason}`),
  ];
  return `${lines.join("\n")}\n`;
}

/**
 * Flag evaluations are cached for a few minutes after a PATCH, so people
 * first exposed right after a change may still get the old split.
 */
export const SRM_GRACE_MS = 15 * 60 * 1000;

/** Start of the SRM window: the last allocation change or SRM clearance, plus the grace period. */
async function srmWindowStart(definition: ExperimentDefinition, log: PaywallExperimentLog | null): Promise<string> {
  const [allocation, cleared] = log
    ? await Promise.all([log.lastChangeAt(definition.key, "allocation_changed"), log.lastChangeAt(definition.key, "srm_cleared")])
    : [null, null];
  const latest = [allocation, cleared].filter((date): date is Date => date !== null).sort((a, b) => b.getTime() - a.getTime())[0];
  const start = latest ? new Date(latest.getTime() + SRM_GRACE_MS) : new Date(`${definition.startDate}T00:00:00Z`);
  return start.toISOString().replace(/\.\d+Z$/, "Z");
}

export type RunOptimizerInput = {
  readonly definition: ExperimentDefinition;
  readonly api: PostHogApi;
  /** Absent in a dry run without a database: no previous run, no change log. */
  readonly log: PaywallExperimentLog | null;
  readonly dryRun: boolean;
  readonly now: Date;
  /** Used when the flag does not exist yet (dry run before creation). */
  readonly seedFlag?: PostHogFlag;
  readonly actor: string;
  /**
   * Write the traffic split to the flag. False is observe mode: the run, its
   * report and copy changes are recorded, the allocation is only proposed.
   */
  readonly applyAllocation?: boolean;
};

type QueueState = {
  /** Queued variants that may go live now, in queue order. */
  readonly promotable: readonly string[];
  /** Every variant still waiting in the queue (promotable or blocked for now). */
  readonly waiting: readonly string[];
  /** Why a waiting variant cannot be promoted yet (reported). */
  readonly blocked: readonly string[];
};

/**
 * The challenger queue: the experiment's reviewed `queue` order, minus
 * variants that were ever promoted or retired (a variant an operator set to
 * 0% is not in the queue, so it is never brought back), minus variants at
 * traffic. A waiting variant is promotable only when its payload passes the
 * validator and the experiment's own gate (servable now, app adoption).
 */
async function promotableVariants(
  definition: ExperimentDefinition,
  flag: PostHogFlag,
  api: PostHogApi,
  log: PaywallExperimentLog | null,
): Promise<QueueState> {
  const used = log ? await log.variantsWithChange(definition.key, ["variant_promoted", "variant_retired"]) : new Set<string>();
  const rollout = new Map(flag.variants.map((variant) => [variant.key, variant.rolloutPercentage]));
  const waiting = (definition.queue ?? []).filter((variant) => rollout.get(variant) === 0 && !used.has(variant));
  const promotable: string[] = [];
  const blocked: string[] = [];
  for (const variant of waiting) {
    const payload = parsedPayload(flag.payloads[variant]);
    const validation = definition.validatePayload(payload, variant);
    const gate = validation.ok ? await definition.promotionGate?.(variant, payload, api) ?? null : "its payload fails the copy validator";
    if (gate) blocked.push(`queued ${variant} cannot be promoted yet: ${gate}`);
    else promotable.push(variant);
  }
  return { promotable, waiting, blocked };
}

function runDecision(
  definition: ExperimentDefinition,
  flag: PostHogFlag,
  found: PostHogFlag | null,
  stats: readonly VariantStats[],
  now: Date,
  promotable: readonly string[],
): OptimizerDecision {
  const decision = decideAllocation(definition, flag, stats, seededRandom(`${definition.key}:${now.toISOString().slice(0, 10)}`), promotable);
  if (!found || found.active) return decision;
  return {
    ...decision,
    target: Object.fromEntries(flag.variants.map((variant) => [variant.key, variant.rolloutPercentage])),
    changed: false,
    reasons: ["hold: the flag is off (kill switch)"],
  };
}

function variantSnapshots(
  definition: ExperimentDefinition,
  flag: PostHogFlag,
  stats: readonly VariantStats[],
  decision: OptimizerDecision,
  queued: ReadonlySet<string>,
): VariantSnapshot[] {
  return flag.variants.map((variant) => {
    const stat = stats.find((item) => item.variant === variant.key);
    const payload = parsedPayload(flag.payloads[variant.key]);
    const validation = definition.validatePayload(payload, variant.key);
    const after = decision.target[variant.key] ?? 0;
    return {
      variant: variant.key,
      name: variant.name ?? null,
      status: after > 0 ? "live" : queued.has(variant.key) ? "queued" : "retired",
      rolloutBefore: variant.rolloutPercentage,
      rolloutAfter: after,
      exposures: stat?.exposures ?? 0,
      conversions: stat?.conversions ?? 0,
      probabilityBest: decision.probabilityBest[variant.key] ?? null,
      secondary: stat?.secondary ?? {},
      guardrails: stat?.guardrails ?? {},
      payload,
      payloadHash: payloadHash(payload),
      payloadErrors: validation.ok ? [] : validation.errors,
    };
  });
}

export async function runOptimizer(input: RunOptimizerInput): Promise<OptimizerRunResult> {
  const { definition, api, log, now } = input;
  const found = await api.flag(definition.flagKey);
  const flag = found ?? input.seedFlag;
  if (!flag) throw new Error(`Flag ${definition.flagKey} does not exist`);
  const allocationSince = await srmWindowStart(definition, log);
  const stats = await fetchVariantStats(api, definition, flag.variants.map((variant) => variant.key), allocationSince);
  const queue = await promotableVariants(definition, flag, api, log);
  const decided = runDecision(definition, flag, found, stats, now, queue.promotable);
  const decision: OptimizerDecision = { ...decided, reasons: [...decided.reasons, ...queue.blocked] };
  const variants = variantSnapshots(definition, flag, stats, decision, new Set(queue.waiting));
  if (!input.dryRun) {
    if (!found) throw new Error(`Flag ${definition.flagKey} does not exist; create it before a live run`);
    if (!log) throw new Error("A live run needs the experiment log (DATABASE_URL)");
  }
  // Every read happens before the flag write, so a failed read cannot leave a
  // written split without its allocation_changed row.
  const mismatches = await clientVariantMismatches(api, definition);
  const previous = log ? await log.latestRun(definition.key) : null;
  const writeFailure = !input.dryRun && input.applyAllocation !== false && decision.changed
    ? await writeAllocation(api, found!, decision.target)
    : null;
  // A failed flag write (for example a key without write scope) leaves this
  // run in observe mode: the split is proposed and reported, not logged as applied.
  const apply = input.applyAllocation !== false && writeFailure === null;
  const snapshot: OptimizerSnapshot = {
    experiment: definition.key,
    platform: definition.platform,
    flagFound: Boolean(found),
    dryRun: input.dryRun,
    allocationApplied: !input.dryRun && apply && decision.changed,
    allocationSince,
    clientVariantMismatches: mismatches,
    decision,
    variants,
  };
  const wasHalted = previous?.halted === true;
  const logged = apply ? decision : { ...decision, changed: false, retire: [], promote: [] };
  const changes = changeLog(definition, variants, logged, previous, input.actor)
    // Log a halt once, when it starts; the run's report repeats it daily.
    .filter((change) => change.kind !== "srm_halt" || !wasHalted);
  const report = optimizerReport(definition, snapshot, changes, now) + modeNote(input.dryRun, apply, writeFailure);
  if (!input.dryRun && log) {
    // Stamp after the flag write, so the next SRM window starts after the new split is live.
    const writtenAt = new Date();
    await log.appendChanges(changes.map((change) => ({ ...change, changedAt: writtenAt })));
    await log.recordRun({ experiment: definition.key, ranAt: now, halted: decision.halted, snapshot, reportMarkdown: report });
  }
  return { snapshot, changes, report, writeFailure };
}

function modeNote(dryRun: boolean, apply: boolean, writeFailure: string | null): string {
  if (writeFailure) return `\nFlag write failed (${writeFailure}); this run stayed in observe mode.\n`;
  if (apply || dryRun) return "";
  return "\nObserve mode: the allocation above is proposed, not written to the flag.\n";
}

/** Writes the split; returns the failure instead of throwing, so the run still records itself. */
async function writeAllocation(api: PostHogApi, flag: PostHogFlag, target: Readonly<Record<string, number>>): Promise<string | null> {
  try {
    await api.setVariantRollouts(flag, target);
    return null;
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 300) : String(error).slice(0, 300);
    console.error("billing.paywall.optimizer_flag_write_failed", { flag: flag.key, error: message });
    return message;
  }
}

/** The flag as the seed would create it, for dry runs before the flag exists. */
export function seedFlag(definition: Record<string, unknown>): PostHogFlag {
  return parsePostHogFlag({ id: 0, deleted: false, ...definition });
}
