/**
 * What the pricing pages show for the cmux Cloud $1 pass, derived from the
 * constants in cloudIntro.ts so the page states no number of its own. Pure:
 * no React, no I/O.
 */
import {
  CLOUD_INTRO_BILLING_COPY,
  CLOUD_INTRO_INCLUDED,
  CLOUD_INTRO_KEEP_DAYS,
  CLOUD_INTRO_MACHINES,
  CLOUD_INTRO_PRICING_USD,
  CLOUD_INTRO_RELEASE_WEEKS,
  CLOUD_INTRO_TERM_DAYS,
} from "./cloudIntro";

const MINUTES_PER_HOUR = 60;

export type CloudIntroOfferFacts = {
  readonly priceUsd: number;
  readonly termDays: number;
  readonly chiefVcpu: number;
  readonly chiefGib: number;
  readonly chiefHours: number;
  readonly chiefHoursWeekly: number;
  readonly machineMinutes: number;
  readonly machineMinutesWeekly: number;
  /** Hours the machine-minutes last on the smallest machine; a larger one spends them faster. */
  readonly machineMinuteHours: number;
  readonly otherVcpu: number;
  readonly otherGib: number;
  readonly concurrentMachines: number;
  readonly keepDays: number;
};

export function cloudIntroOfferFacts(): CloudIntroOfferFacts {
  const { chief, otherMax } = CLOUD_INTRO_MACHINES;
  return {
    priceUsd: CLOUD_INTRO_PRICING_USD.billedAmount,
    termDays: CLOUD_INTRO_TERM_DAYS,
    chiefVcpu: chief.vcpu,
    chiefGib: chief.gib,
    chiefHours: CLOUD_INTRO_INCLUDED.chiefAwakeHours,
    chiefHoursWeekly: CLOUD_INTRO_INCLUDED.chiefAwakeHours / CLOUD_INTRO_RELEASE_WEEKS,
    machineMinutes: CLOUD_INTRO_INCLUDED.machineMinutes,
    machineMinutesWeekly: CLOUD_INTRO_INCLUDED.machineMinutes / CLOUD_INTRO_RELEASE_WEEKS,
    machineMinuteHours: CLOUD_INTRO_INCLUDED.machineMinutes / (chief.vcpu * MINUTES_PER_HOUR),
    otherVcpu: otherMax.vcpu,
    otherGib: otherMax.gib,
    concurrentMachines: CLOUD_INTRO_INCLUDED.concurrentMachines,
    keepDays: CLOUD_INTRO_KEEP_DAYS,
  };
}

/** The three layouts of the pass on the cmux NEXT pricing preview, for a taste decision. */
export const CLOUD_INTRO_LAYOUTS = ["a", "b", "c"] as const;
export type CloudIntroLayout = (typeof CLOUD_INTRO_LAYOUTS)[number];

/** `?intro=` on the preview page; anything else is the recommended slim band, `a`. */
export function cloudIntroLayout(value: string | string[] | undefined): CloudIntroLayout {
  const raw = Array.isArray(value) ? value[0] : value;
  return (CLOUD_INTRO_LAYOUTS as readonly string[]).includes(raw ?? "") ? raw as CloudIntroLayout : "a";
}

export type CloudIntroBillingCode = keyof typeof CLOUD_INTRO_BILLING_COPY;

/** The pass's `/pricing?billing=` code, or null for any other value. */
export function cloudIntroBillingCode(value: string | null | undefined): CloudIntroBillingCode | null {
  return value && Object.hasOwn(CLOUD_INTRO_BILLING_COPY, value) ? value as CloudIntroBillingCode : null;
}
