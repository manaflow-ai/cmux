// This month's Cloud usage as the panel shows it (`cloud.usage.current`). The billing owner prices every
// meter (`usd`); this file only turns its seconds into the units the prices are quoted in (vCPU-hours,
// GiB-hours, GiB-months) and names a card. It computes no price.
import type { CloudUsage } from "./ops";
import { intl } from "../../ui/intl";

const HOUR = 3600;
/** Hours in an average month (365 days / 12), as cost.ts quotes a paused machine by the month. */
const MONTH_HOURS = 730;

export type UsageMeter = "vcpu" | "memory" | "stored";

/** The catalog types a number as `number | "Infinity" | "-Infinity" | "NaN"`; the panel shows only finite ones. */
function finite(value: number | string): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

/** The month's total in dollars, as the server priced it. */
export function monthTotal(usage: CloudUsage): number {
  return finite(usage.usd.total);
}

/** One meter's amount in its quoted unit, and the server's dollars for it. */
export function meterAmount(usage: CloudUsage, meter: UsageMeter): { amount: number; usd: number } {
  const seconds =
    meter === "vcpu" ? usage.vcpu_seconds : meter === "memory" ? usage.memory_gib_seconds : usage.stored_gib_seconds;
  const amount = meter === "stored" ? finite(seconds) / (MONTH_HOURS * HOUR) : finite(seconds) / HOUR;
  return { amount: Math.max(0, amount), usd: finite(usage.usd[meter]) };
}

/** "12.5", "0.03": at most two significant decimals below 1, one above. */
export function quantity(value: number, language: string): string {
  const digits = value > 0 && value < 1 ? 2 : 1;
  return intl.NumberFormat(language, { maximumFractionDigits: digits }).format(value);
}

const BRANDS: Record<string, string> = {
  amex: "American Express",
  american_express: "American Express",
  diners: "Diners Club",
  discover: "Discover",
  jcb: "JCB",
  mastercard: "Mastercard",
  unionpay: "UnionPay",
  visa: "Visa",
};

/** The card network's own name ("visa" -> "Visa"); an unknown one is capitalized; none is undefined. */
export function cardBrand(brand: string | null | undefined): string | undefined {
  const key = brand?.trim().toLowerCase();
  if (!key) return undefined;
  return BRANDS[key] ?? key.charAt(0).toUpperCase() + key.slice(1);
}

/** The month has spans the meter has not counted yet. */
export function hasGaps(usage: CloudUsage): boolean {
  return usage.gaps.length > 0;
}

/** Payments run in the processor's test mode: the panel says so in small text. */
export function testMode(usage: CloudUsage): boolean {
  return usage.stripe_mode === "test";
}
