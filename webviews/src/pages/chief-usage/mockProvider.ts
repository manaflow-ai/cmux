// l10n-allow-file: dev and gallery fixtures (Chief names, model ids), not shipped UI.
// An in-memory `cmux.chief_usage.summary` provider for the browser dev loop (`/chief-usage/?mock`)
// and the gallery: 30 deterministic days of a Chief's usage ledger, folded the way
// `optchat-chief usage --json` folds it. Chief turns cost about $0.07 to $0.30, compactor nodes run
// on the cheap claude-haiku-5-5, three subagents (a102, a132, a241) cost $3 to $80 in all, and the
// cache hit rate jumps from about 40 % to about 98 % on Oct 19 (a226's X-Subrouter-Session fix).
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import {
  ChiefUsageOps,
  type UsageBucket,
  type UsageBy,
  type UsageGroup,
  type UsageKind,
  type UsagePoint,
  type UsageQuery,
  type UsageSummary,
  type UsageTopUnit,
  type UsageTotals,
  type UsageWindow,
} from "./types";

const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;

/** The instant the fixture's ledger ends: 2026-10-20 18:00 local. */
export const FIXTURE_NOW = new Date(2026, 9, 20, 18).getTime();
/** a226's cache fix landed on the morning of Oct 19. */
const CACHE_FIX = new Date(2026, 9, 19, 9).getTime();

/** `busy` is a working Chief; `empty` has no usage in range yet. */
export type MockUsageKind = "busy" | "empty";

export class MockChiefUsageProvider implements PageClient {
  constructor(
    private readonly kind: MockUsageKind = "busy",
    private readonly failure?: { code: string; message: string },
    private readonly now: number = FIXTURE_NOW,
  ) {}

  async call<R>(op: string, params: unknown): Promise<R> {
    if (this.failure) throw pageError(this.failure.code, this.failure.message);
    if (op !== ChiefUsageOps.summary) throw pageError("cmux.op.unknown", op);
    const { since = "7d", by = "chief", top = 10 } = (params ?? {}) as Partial<UsageQuery>;
    return mockUsageSummary(this.kind, { since, by, top }, this.now) as R;
  }

  async subscribe(): Promise<() => void> {
    return () => {};
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }
}

/** One ledger line after the reader derived per-unit cost. */
export interface MockUnit {
  ts: number;
  chief: string;
  kind: UsageKind;
  agent: string | null;
  key: string;
  model: string;
  harness: string;
  input: number;
  output: number;
  cache_read: number;
  cache_write: number;
  usd: number;
  ms: number;
  ttft_ms: number;
  start_ms: number;
}

const CHIEFS = [
  { id: "default", label: "Chief", home: "~/.cmux/mux" },
  { id: "research", label: "Research", home: "~/.cmux/mux/c/research" },
];

const WINDOW_MS: Record<UsageWindow, number> = {
  "24h": DAY_MS,
  "7d": 7 * DAY_MS,
  "30d": 30 * DAY_MS,
  "90d": 90 * DAY_MS,
  "1y": 365 * DAY_MS,
};

/** The tool's rule: ≤ 2 d hour, ≤ 60 d day, ≤ 1 y week, else month. */
export function bucketFor(windowMs: number): UsageBucket {
  if (windowMs <= 2 * DAY_MS) return "hour";
  if (windowMs <= 60 * DAY_MS) return "day";
  if (windowMs <= 365 * DAY_MS) return "week";
  return "month";
}

/** The local-time start of the bucket holding `at`. */
export function bucketStart(at: number, bucket: UsageBucket): number {
  const date = new Date(at);
  if (bucket === "hour") {
    date.setMinutes(0, 0, 0);
    return date.getTime();
  }
  date.setHours(0, 0, 0, 0);
  if (bucket === "week") date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
  if (bucket === "month") date.setDate(1);
  return date.getTime();
}

function nextBucket(start: number, bucket: UsageBucket): number {
  const date = new Date(start);
  if (bucket === "hour") date.setHours(date.getHours() + 1);
  else if (bucket === "day") date.setDate(date.getDate() + 1);
  else if (bucket === "week") date.setDate(date.getDate() + 7);
  else date.setMonth(date.getMonth() + 1);
  return date.getTime();
}

/** mulberry32: a small seeded generator so every run draws the same ledger. */
function random(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

/** Prompt tokens split at hit rate `hit` (read / (read + write + input)). */
function promptTokens(total: number, hit: number, inputShare: number) {
  const cache_read = Math.round(total * hit);
  const rest = total - cache_read;
  const input = Math.round(rest * inputShare);
  return { cache_read, input, cache_write: rest - input };
}

/** The 30 days of ledger lines that end at `now`, oldest first. */
export function mockUnits(now: number = FIXTURE_NOW): MockUnit[] {
  const next = random(0xc41ef);
  const between = (low: number, high: number) => low + next() * (high - low);
  const units: MockUnit[] = [];
  const firstDay = bucketStart(now, "day") - 29 * DAY_MS;
  let message = 1_200;
  let node = 5_100;
  for (let day = 0; day < 30; day++) {
    const midnight = new Date(firstDay + day * DAY_MS + 12 * HOUR_MS);
    midnight.setHours(0, 0, 0, 0);
    const weekend = midnight.getDay() === 0 || midnight.getDay() === 6;
    const turns = Math.round(weekend ? between(2, 7) : between(10, 24));
    for (let index = 0; index < turns; index++) {
      const ts = midnight.getTime() + between(9, 23.5) * HOUR_MS;
      if (ts > now) continue;
      const fixed = ts >= CACHE_FIX;
      const hit = fixed ? between(0.96, 0.99) : between(0.33, 0.47);
      const slow = next() < 0.06;
      const ms = Math.round((fixed ? between(3_800, 8_900) : between(7_000, 16_500)) * (slow ? between(3, 6) : 1));
      const chief = next() < 0.85 ? "default" : "research";
      message += Math.round(between(2, 9));
      units.push({
        ts,
        chief,
        kind: "turn",
        agent: null,
        key: `turn:optchat:${message}`,
        model: "claude-opus-5-5",
        harness: "claude",
        ...promptTokens(Math.round(between(140_000, 290_000)), hit, 0.06),
        output: Math.round(between(600, 3_400)),
        usd: Number(((fixed ? between(0.07, 0.14) : between(0.15, 0.3)) * (slow ? 1.8 : 1)).toFixed(4)),
        ms,
        ttft_ms: Math.round(ms * between(0.35, 0.6)),
        start_ms: Math.round(between(900, 3_400)),
      });
      // Each turn's messages fold into compactor nodes on the cheap model.
      const nodes = Math.round(between(1, 4));
      for (let n = 0; n < nodes; n++) {
        node += 1;
        units.push({
          ts: ts + between(10_000, 120_000),
          chief,
          kind: "compactor",
          agent: null,
          key: `node:${node}+${Math.round(between(2, 6))}`,
          model: "claude-haiku-5-5",
          harness: "claude",
          ...promptTokens(Math.round(between(4_000, 14_000)), fixed ? between(0.7, 0.9) : between(0.1, 0.3), 0.5),
          output: Math.round(between(250, 900)),
          usd: Number(between(0.002, 0.011).toFixed(4)),
          ms: Math.round(between(1_800, 6_000)),
          ttft_ms: Math.round(between(500, 1_400)),
          start_ms: Math.round(between(700, 1_900)),
        });
      }
    }
  }
  // Subagents: a102 a short research run, a132 a Codex reviewer over three days, a241 a week-long
  // build-out that runs past the cache fix.
  const subagents = [
    { agent: "a102", model: "claude-opus-5-5", harness: "claude", day: 8, days: 1, prompts: 6, usd: [0.4, 0.8] },
    { agent: "a132", model: "gpt-5.5-codex", harness: "codex", day: 14, days: 3, prompts: 14, usd: [0.9, 1.9] },
    { agent: "a241", model: "claude-opus-5-5", harness: "claude", day: 23, days: 7, prompts: 38, usd: [1.4, 2.8] },
  ] as const;
  for (const sub of subagents) {
    const perDay = Math.ceil(sub.prompts / sub.days);
    for (let prompt = 0; prompt < sub.prompts; prompt++) {
      const ts = firstDay + (sub.day + Math.floor(prompt / perDay)) * DAY_MS + between(10, 20) * HOUR_MS;
      if (ts > now) continue;
      const fixed = ts >= CACHE_FIX;
      units.push({
        ts,
        chief: "default",
        kind: "subagent",
        agent: sub.agent,
        key: `subagent:${sub.agent}:${prompt + 1}`,
        model: sub.model,
        harness: sub.harness,
        ...promptTokens(Math.round(between(400_000, 1_400_000)), fixed ? between(0.95, 0.99) : between(0.3, 0.5), 0.1),
        output: Math.round(between(4_000, 22_000)),
        usd: Number((between(sub.usd[0], sub.usd[1]) * (fixed ? 0.45 : 1)).toFixed(4)),
        ms: Math.round(between(40_000, 240_000)),
        ttft_ms: Math.round(between(2_000, 9_000)),
        start_ms: Math.round(between(900, 2_400)),
      });
    }
  }
  return units.sort((a, b) => a.ts - b.ts);
}

/** Nearest-rank percentile of `values` (sorted here); null when empty. */
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))]!;
}

export function fold(units: MockUnit[]): UsageTotals {
  const sum = (field: "input" | "output" | "cache_read" | "cache_write" | "usd") =>
    units.reduce((total, unit) => total + unit[field], 0);
  const input = sum("input");
  const cache_read = sum("cache_read");
  const cache_write = sum("cache_write");
  const prompt = input + cache_read + cache_write;
  const turns = units.filter((unit) => unit.kind === "turn");
  return {
    units: units.length,
    turns: turns.length,
    input,
    output: sum("output"),
    cache_read,
    cache_write,
    usd: Number(sum("usd").toFixed(4)),
    hit: prompt > 0 ? cache_read / prompt : null,
    ms_p50: percentile(
      turns.map((unit) => unit.ms),
      0.5,
    ),
    ms_p95: percentile(
      turns.map((unit) => unit.ms),
      0.95,
    ),
    ttft_p50: percentile(
      turns.map((unit) => unit.ttft_ms),
      0.5,
    ),
    ttft_p95: percentile(
      turns.map((unit) => unit.ttft_ms),
      0.95,
    ),
    start_p50: percentile(
      turns.map((unit) => unit.start_ms),
      0.5,
    ),
    start_p95: percentile(
      turns.map((unit) => unit.start_ms),
      0.95,
    ),
  };
}

function groupKey(unit: MockUnit, by: UsageBy): { key: string; label: string } {
  switch (by) {
    case "chief": {
      const chief = CHIEFS.find((entry) => entry.id === unit.chief);
      return { key: unit.chief, label: chief?.label ?? unit.chief };
    }
    case "agent":
      return { key: unit.agent ?? "", label: unit.agent ?? "" };
    case "model":
      return { key: unit.model, label: unit.model };
    case "harness":
      return { key: unit.harness, label: unit.harness };
    case "kind":
      return { key: unit.kind, label: unit.kind };
  }
}

// As optchat-chief usage.rs links: a subagent's chat by its session in the Chief home
// (`cmux://chief/<home id>/session/<session>`); turns and compactor nodes have no link yet.
function link(unit: MockUnit): string | null {
  if (unit.kind === "subagent" && unit.agent) return `cmux://chief/1a2b3c4d/session/01a15-${unit.agent}`;
  return null;
}

/** The summary `optchat-chief usage --json --since <since> --by <by> --top <top>` would print. */
export function mockUsageSummary(kind: MockUsageKind, query: UsageQuery, now: number = FIXTURE_NOW): UsageSummary {
  const span = WINDOW_MS[query.since];
  const since = now - span;
  const bucket = bucketFor(span);
  const units = kind === "busy" ? mockUnits(now).filter((unit) => unit.ts >= since && unit.ts <= now) : [];
  const series: UsagePoint[] = [];
  for (let start = bucketStart(since, bucket); start <= now; start = nextBucket(start, bucket)) {
    const end = nextBucket(start, bucket);
    const {
      units: count,
      turns,
      input,
      output,
      cache_read,
      cache_write,
      usd,
      hit,
      ms_p50,
      ms_p95,
    } = fold(units.filter((unit) => unit.ts >= start && unit.ts < end));
    series.push({ t: start, units: count, turns, input, output, cache_read, cache_write, usd, hit, ms_p50, ms_p95 });
  }
  const groups = new Map<string, { label: string; units: MockUnit[] }>();
  for (const unit of units) {
    const { key, label } = groupKey(unit, query.by);
    const group = groups.get(key) ?? { label, units: [] };
    group.units.push(unit);
    groups.set(key, group);
  }
  const by: UsageGroup[] = [...groups.entries()]
    .map(([key, group]) => ({ key, label: group.label, ...fold(group.units) }))
    .sort((a, b) => b.usd - a.usd);
  const top: UsageTopUnit[] = [...units]
    .sort((a, b) => b.usd - a.usd)
    .slice(0, query.top)
    .map((unit) => ({
      ts: unit.ts,
      chief: unit.chief,
      kind: unit.kind,
      agent: unit.agent,
      key: unit.key,
      model: unit.model,
      usd: unit.usd,
      input: unit.input,
      output: unit.output,
      cache_read: unit.cache_read,
      cache_write: unit.cache_write,
      ms: unit.ms,
      link: link(unit),
    }));
  return { v: 1, since, until: now, bucket, chiefs: CHIEFS, totals: fold(units), series, by, top };
}
