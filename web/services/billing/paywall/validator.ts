// Copy safety for experiment payloads. Every payload is checked before it is
// served; a payload that fails is never shown (the caller serves control and
// logs the errors). Shared by the iOS paywall and the web pricing page, so the
// copy rules are separate from the iOS payload schema.

import {
  FACT_NUMBERS,
  FACT_QUANTITIES,
  FREE_TRIAL_AVAILABLE,
  UNLIMITED_PHRASES,
  UNSUPPORTED_CLAIMS,
  type FactUnit,
} from "./facts";

export type CopyContext = {
  /**
   * Whether the variant sells a free trial. Trial wording is allowed only
   * when the variant offers one and a trial product exists.
   */
  readonly offersTrial?: boolean;
  /** Overrides FREE_TRIAL_AVAILABLE (the trial experiment sets this). */
  readonly trialAvailable?: boolean;
  /** Extra quantities the variant may state, e.g. `"7 day"` for a 7-day trial. */
  readonly extraQuantities?: readonly string[];
};

/**
 * Names of vendors and internal systems that must never reach user copy, and
 * App Store internals that are not user terms.
 */
export const BANNED_NAMES: readonly string[] = [
  "stripe",
  "freestyle",
  "posthog",
  "stack",
  "stack auth",
  "hexclave",
  "vercel",
  "planetscale",
  "blaxel",
  "axiom",
  "sentry",
  "cloudflare",
  "aws",
  "amazon",
  "gcp",
  "google cloud",
  "tailscale",
  "iroh",
  "openai",
  "anthropic",
  "storekit",
  "testflight",
  "sandbox",
  "app store connect",
  "appaccounttoken",
  "transaction id",
  "intro offer",
  "introductory offer",
  "offer code",
  "subscription group",
];

/** Marketing phrases that are false or unverifiable for any plan. */
export const BANNED_PHRASES: readonly string[] = [
  "guaranteed",
  "guarantee",
  "best",
  "#1",
  "number one",
  "no. 1",
  "limited time",
  "limited-time",
  "act now",
  "hurry",
  "last chance",
  "today only",
];

/** Letters, digits, spaces and ordinary sentence punctuation; nothing that formats or links. */
const PLAIN_TEXT = /^[\p{L}\p{N} .,;:!?'’"“”()\-–—/&]*$/u;
const URL_LIKE = /(?:[a-z][a-z0-9+.-]*:\/\/|www\.|\b[a-z0-9-]+\.(?:com|dev|io|app|net|org|ai|co|sh|me|so|xyz)\b)/i;
const ONLY_N_LEFT = /\bonly\s+\p{N}+\s+(?:\p{L}+\s+)?left\b/iu;
const NUMBER_WITH_UNIT = /(\p{N}+(?:[.,]\p{N}+)?)(?:\s*-\s*|\s+)?([\p{L}]+(?:-[\p{L}]+)?)?/gu;

const UNIT_ALIASES: Readonly<Record<string, FactUnit>> = {
  vm: "vm",
  vms: "vm",
  cloud: "vm",
  machine: "vm",
  machines: "vm",
  vcpu: "vcpu",
  vcpus: "vcpu",
  cpu: "vcpu",
  cpus: "vcpu",
  core: "vcpu",
  cores: "vcpu",
  gb: "gb",
  "vm-hour": "vm-hour",
  "vm-hours": "vm-hour",
  hour: "vm-hour",
  hours: "vm-hour",
  day: "day",
  days: "day",
};

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Whole-word, case-insensitive phrase match. `#1` and `24/7` have no word edge, so they match anywhere. */
function containsPhrase(text: string, phrase: string): boolean {
  const body = escapeRegExp(phrase).replace(/\s+/g, "\\s+");
  const start = /^[\p{L}\p{N}]/u.test(phrase) ? "(?<![\\p{L}\\p{N}])" : "";
  const end = /[\p{L}\p{N}]$/u.test(phrase) ? "(?![\\p{L}\\p{N}])" : "";
  return new RegExp(`${start}${body}${end}`, "iu").test(text);
}

function quantityErrors(field: string, text: string, context: CopyContext): string[] {
  const errors: string[] = [];
  const extra = new Set(context.extraQuantities ?? []);
  for (const match of text.matchAll(NUMBER_WITH_UNIT)) {
    const raw = match[1]!;
    const value = Number(raw.replace(",", "."));
    const unit = match[2] ? UNIT_ALIASES[match[2].toLowerCase()] : undefined;
    if (unit) {
      const quantity = `${value} ${unit}`;
      if (!FACT_QUANTITIES.has(quantity) && !extra.has(quantity)) {
        errors.push(`${field}: "${match[0].trim()}" is not a published quantity`);
      }
    } else if (!FACT_NUMBERS.has(value) && ![...extra].some((item) => item.startsWith(`${value} `))) {
      errors.push(`${field}: the number ${raw} is not in the facts`);
    }
  }
  return errors;
}

function unlimitedErrors(field: string, text: string): string[] {
  const lower = text.toLowerCase();
  let rest = lower;
  for (const phrase of UNLIMITED_PHRASES) rest = rest.split(phrase).join(" ");
  return containsPhrase(rest, "unlimited") ? [`${field}: "unlimited" is allowed only in: ${UNLIMITED_PHRASES.join(", ")}`] : [];
}

function trialErrors(field: string, text: string, context: CopyContext): string[] {
  const mentionsTrial = containsPhrase(text, "trial") || containsPhrase(text, "free for");
  if (!mentionsTrial) return [];
  const available = context.trialAvailable ?? FREE_TRIAL_AVAILABLE;
  if (available && context.offersTrial) return [];
  return [`${field}: trial wording needs a variant that offers a trial product`];
}

/**
 * Errors for one piece of copy, or an empty list when it is safe to show.
 * `maxLength` counts user-perceived characters.
 */
export function copyErrors(
  field: string,
  value: unknown,
  options: { readonly maxLength: number; readonly required?: boolean },
  context: CopyContext = {},
): string[] {
  if (typeof value !== "string") return [`${field}: must be a string`];
  const errors: string[] = [];
  const length = [...new Intl.Segmenter("en", { granularity: "grapheme" }).segment(value)].length;
  if (options.required && value.trim().length === 0) errors.push(`${field}: must not be empty`);
  if (length > options.maxLength) errors.push(`${field}: ${length} characters, limit ${options.maxLength}`);
  if (value !== value.trim()) errors.push(`${field}: leading or trailing whitespace`);
  if (!PLAIN_TEXT.test(value)) errors.push(`${field}: only plain text and sentence punctuation are allowed`);
  if (URL_LIKE.test(value)) errors.push(`${field}: must not contain a link or domain`);
  for (const name of BANNED_NAMES) {
    if (containsPhrase(value, name)) errors.push(`${field}: must not name "${name}"`);
  }
  for (const phrase of BANNED_PHRASES) {
    if (containsPhrase(value, phrase)) errors.push(`${field}: banned phrase "${phrase}"`);
  }
  for (const claim of UNSUPPORTED_CLAIMS) {
    if (containsPhrase(value, claim)) errors.push(`${field}: "${claim}" is not a published fact for these plans`);
  }
  if (ONLY_N_LEFT.test(value)) errors.push(`${field}: scarcity claims are banned`);
  errors.push(...unlimitedErrors(field, value), ...trialErrors(field, value, context), ...quantityErrors(field, value, context));
  return errors;
}

// The iOS paywall payload (contract with the iOS app).

export const IOS_PAYWALL_LAYOUTS = ["cards", "comparison", "focus"] as const;
export const IOS_PAYWALL_CTA_STYLES = ["price", "action"] as const;
export const IOS_PAYWALL_PLAN_IDS = ["pro", "max"] as const;
export const IOS_PAYWALL_BILLING_PERIODS = ["yearly", "monthly"] as const;

export type IosPaywallConfig = {
  readonly experiment: string;
  readonly variant: string;
  readonly layout: (typeof IOS_PAYWALL_LAYOUTS)[number];
  readonly headline: string;
  readonly subheadline: string;
  readonly bullets: readonly string[];
  readonly highlightedPlanId: (typeof IOS_PAYWALL_PLAN_IDS)[number] | null;
  readonly defaultBillingPeriod: (typeof IOS_PAYWALL_BILLING_PERIODS)[number];
  readonly ctaStyle: (typeof IOS_PAYWALL_CTA_STYLES)[number];
  readonly showYearlySavings: boolean;
};

export type ValidationResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly errors: readonly string[] };

const VARIANT_KEY = /^[a-z0-9][a-z0-9-]{0,39}$/;

function oneOf<T extends string>(values: readonly T[], value: unknown): value is T {
  return typeof value === "string" && (values as readonly string[]).includes(value);
}

function iosPaywallShapeErrors(record: Record<string, unknown>, experiment: string, variant: string): string[] {
  const errors: string[] = [];
  if (record.experiment !== undefined && record.experiment !== experiment) errors.push("experiment: does not match the flag");
  if (record.variant !== undefined && record.variant !== variant) errors.push("variant: does not match the flag variant");
  if (!VARIANT_KEY.test(variant)) errors.push("variant: must be a lowercase key");
  if (!oneOf(IOS_PAYWALL_LAYOUTS, record.layout)) errors.push("layout: must be cards, comparison or focus");
  if (record.highlightedPlanId !== null && !oneOf(IOS_PAYWALL_PLAN_IDS, record.highlightedPlanId)) {
    errors.push("highlightedPlanId: must be pro, max or null");
  }
  if (!oneOf(IOS_PAYWALL_BILLING_PERIODS, record.defaultBillingPeriod)) errors.push("defaultBillingPeriod: must be yearly or monthly");
  if (!oneOf(IOS_PAYWALL_CTA_STYLES, record.ctaStyle)) errors.push("ctaStyle: must be price or action");
  if (typeof record.showYearlySavings !== "boolean") errors.push("showYearlySavings: must be a boolean");
  if (!Array.isArray(record.bullets) || record.bullets.length > 5) errors.push("bullets: must be a list of at most 5");
  const allowed = new Set([
    "experiment", "variant", "layout", "headline", "subheadline", "bullets",
    "highlightedPlanId", "defaultBillingPeriod", "ctaStyle", "showYearlySavings",
  ]);
  for (const key of Object.keys(record)) {
    if (!allowed.has(key)) errors.push(`${key}: unknown field`);
  }
  return errors;
}

/**
 * Validates an iOS paywall flag payload for one variant. The payload may
 * omit `experiment` and `variant` (the flag supplies them); every other field
 * is required. A payload stored as a JSON string is parsed first.
 */
export function validateIosPaywallPayload(
  payload: unknown,
  experiment: string,
  variant: string,
  context: CopyContext = {},
): ValidationResult<IosPaywallConfig> {
  let raw = payload;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw);
    } catch {
      return { ok: false, errors: ["payload: not valid JSON"] };
    }
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { ok: false, errors: ["payload: must be an object"] };
  const record = raw as Record<string, unknown>;
  const errors = [
    ...iosPaywallShapeErrors(record, experiment, variant),
    ...copyErrors("headline", record.headline, { maxLength: 60, required: true }, context),
    ...copyErrors("subheadline", record.subheadline, { maxLength: 140 }, context),
    ...(Array.isArray(record.bullets)
      ? record.bullets.flatMap((bullet, index) => copyErrors(`bullets[${index}]`, bullet, { maxLength: 80, required: true }, context))
      : []),
  ];
  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      experiment,
      variant,
      layout: record.layout as IosPaywallConfig["layout"],
      headline: record.headline as string,
      subheadline: record.subheadline as string,
      bullets: [...(record.bullets as string[])],
      highlightedPlanId: record.highlightedPlanId as IosPaywallConfig["highlightedPlanId"],
      defaultBillingPeriod: record.defaultBillingPeriod as IosPaywallConfig["defaultBillingPeriod"],
      ctaStyle: record.ctaStyle as IosPaywallConfig["ctaStyle"],
      showYearlySavings: record.showYearlySavings as boolean,
    },
  };
}
