// The plan's pool of hours and the monthly spend limit past it (cmuxterm-hq RFD 0081, "Caps that enforce
// themselves": "At the end of a pool, paid or trial: machines pause with memory kept, nothing is deleted, and the
// person chooses a monthly spend limit for more minutes (default $0) or a larger plan. No bill grows without a limit
// the person set. Warnings at 80% and 100%.").
//
// The backend decides every number: cmux-platform PoolLimit.ts `poolStanding` answers `cloud.plan.get`'s `pool`
// (the shape agreed with the enforce lane, cmux-platform lane/rfd-0081-0135-build-spend-limit: present only while the
// server's CLOUD_SPEND_LIMIT_ENFORCE is on, null for a non-NEXT plan or an unread month; until it lands the mock serves it). The page
// computes no limit and no warning: it shows the record in hours of the standard machine, and parses what the person
// types the way the server will (PoolLimit.ts parseSpendLimitUsd), so a typo is caught before the confirm sheet.
//
// Behind a default-off switch: the host sets `data-cloud-spend-limit="on"` on <html> from the Debug setting
// `cloud.spendLimit`; the dev loop and the gallery use `?spendLimit=1`. Off, the account panel is unchanged.
import type { CloudPlan } from "./ops";

/** `cloud.plan.get`'s `pool` (cmux-platform PoolLimit.ts PoolStanding, plus the month's end and the rate). */
export interface PoolStanding {
  /** The plan's pool in vCPU-minutes (Plan.ts includedMachineMinutes). */
  included_minutes: number;
  /** The month's vCPU-minutes as shown (Meter.ts shownMinutes). */
  used_minutes: number;
  /** Whole percent used, rounded down; 100 and more once the pool is used up. */
  percent: number;
  /** The highest warning reached this month, or null below 80%. */
  warning: 80 | 100 | null;
  /** vCPU-minutes past the pool this month. */
  overage_minutes: number;
  /** What the time past the pool cost this month, USD. */
  overage_usd: number;
  /** The person's monthly limit past the pool, USD (default 0). */
  spend_limit_usd: number;
  /** False: machines are paused with memory kept, and starts are refused until a raise, a larger plan or next month. */
  may_run: boolean;
  /** When the month resets (ms). */
  period_end?: number | null;
  /** USD per vCPU-hour past the pool (Margin.ts NEXT_OVERAGE_VCPU_HOUR_USD, 0.02). */
  overage_vcpu_hour_usd?: number;
  /** vCPUs of the machine hours are counted in (Plan.ts NEXT_STANDARD_MACHINE_VCPUS, 4; the server may omit it). */
  machine_vcpus?: number;
  /** The warnings already sent this month. */
  warnings_sent?: (80 | 100)[];
}

/**
 * The setter's refusals (enforce lane): `cloud.spend_limit.forbidden` (not a team admin), `cloud.spend_limit.off`
 * (the server's CLOUD_SPEND_LIMIT_ENFORCE switch is off) and `cloud.spend_limit.invalid`. Read from the app server's
 * `cmux.cloud.*` code or, from a server that does not declare them yet, from `upstream_code`.
 */
export function spendLimitRefusal(error: unknown): "forbidden" | "off" | "invalid" | undefined {
  const e = (error && typeof error === "object" ? error : {}) as { code?: unknown; upstream_code?: unknown };
  const codes = [e.code, e.upstream_code].filter((code): code is string => typeof code === "string");
  for (const code of codes) {
    if (code === "cmux.cloud.forbidden" || /spend_limit[._]forbidden$/.test(code)) return "forbidden";
    if (/spend_limit[._]off$/.test(code)) return "off";
    if (/spend_limit[._]invalid$/.test(code)) return "invalid";
  }
  return undefined;
}

/** The setter, run as a native action: a money change, so the host confirms it (ops.ts NATIVE_ACTIONS rule). */
export const SPEND_LIMIT_SET = "cmux.cloud.plan.spend_limit.set";
/** The largest limit (PoolLimit.ts MAX_SPEND_LIMIT_USD). */
export const MAX_SPEND_LIMIT_USD = 10_000;
const DEFAULT_VCPUS = 4;
const DEFAULT_VCPU_HOUR_USD = 0.02;

/** Whether the switch is on: the host's data attribute, else the dev loop's `?spendLimit=1`. Default off. */
export function spendLimitEnabled(
  root: { dataset: DOMStringMap } | undefined = typeof document === "undefined" ? undefined : document.documentElement,
  search: string = typeof location === "undefined" ? "" : location.search,
): boolean {
  const attr = root?.dataset.cloudSpendLimit;
  if (attr !== undefined) return attr === "on";
  return new URLSearchParams(search).get("spendLimit") === "1";
}

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/** The plan's pool, when the server sends a whole one. */
export function poolOf(plan: CloudPlan | undefined): PoolStanding | undefined {
  const pool = (plan as (CloudPlan & { pool?: unknown }) | undefined)?.pool as Partial<PoolStanding> | undefined;
  if (!pool || typeof pool !== "object") return undefined;
  const { included_minutes, used_minutes, percent, overage_usd, spend_limit_usd } = pool;
  if (![included_minutes, used_minutes, percent, overage_usd, spend_limit_usd].every(finite)) return undefined;
  return pool as PoolStanding;
}

/** Hours of the standard machine for `minutes` vCPU-minutes. */
export function hoursOf(minutes: number, pool: Pick<PoolStanding, "machine_vcpus">): number {
  return minutes / ((pool.machine_vcpus ?? DEFAULT_VCPUS) * 60);
}

/** USD for an hour of the standard machine past the pool ($0.08). */
export function hourRateUsd(pool: Pick<PoolStanding, "machine_vcpus" | "overage_vcpu_hour_usd">): number {
  return (pool.overage_vcpu_hour_usd ?? DEFAULT_VCPU_HOUR_USD) * (pool.machine_vcpus ?? DEFAULT_VCPUS);
}

/** The hours a limit buys past the pool, rounded down. */
export function hoursFor(limitUsd: number, pool: Pick<PoolStanding, "machine_vcpus" | "overage_vcpu_hour_usd">) {
  const rate = hourRateUsd(pool);
  return rate > 0 ? Math.floor(limitUsd / rate) : 0;
}

/** What the panel's state is: inside the pool, warned at 80%, past it on the limit, or paused at the end. */
export type PoolState = "ok" | "near" | "overage" | "paused";

export function poolState(pool: PoolStanding): PoolState {
  if (!pool.may_run) return "paused";
  if (pool.warning === 100) return "overage";
  if (pool.warning === 80) return "near";
  return "ok";
}

/**
 * A limit as typed: USD from 0 to MAX_SPEND_LIMIT_USD, rounded down to the cent; anything else null (PoolLimit.ts
 * parseSpendLimitUsd, so the page refuses what the server would). A leading "$" and thousands commas are allowed.
 */
export function parseSpendLimit(raw: string): number | null {
  const text = raw.trim().replace(/^\$/, "").replace(/,/g, "").trim();
  if (text === "" || !/^\d*\.?\d*$/.test(text)) return null;
  const value = Number(text);
  if (!Number.isFinite(value) || value < 0 || value > MAX_SPEND_LIMIT_USD) return null;
  return Math.floor(Math.round(value * 1_000) / 10) / 100;
}
