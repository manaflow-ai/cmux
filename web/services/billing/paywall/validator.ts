// Copy safety for experiment payloads. Every payload is checked before it is
// served; a payload that fails is never shown (the caller serves control and
// logs the errors). Shared by the iOS paywall and the web pricing page, so the
// copy rules are separate from the iOS payload schema.

import {
  FACT_QUANTITIES,
  FREE_TRIAL_AVAILABLE,
  PLAN_FACT_QUANTITIES,
  UNLIMITED_PHRASES,
  UNSUPPORTED_CLAIMS,
  type FactPlan,
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
  // Price claims come from the store, never from copy.
  "discount",
  "sale",
];

/** Numbers must be digits followed by their unit, so they can be checked against the facts. */
const NUMBER_WORDS: readonly string[] = [
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
  "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "sixty", "eighty",
  "hundred", "hundreds", "thousand", "thousands", "million", "millions", "dozen", "dozens",
  "double", "twice", "triple", "half",
];

/**
 * Latin letters, ASCII digits, spaces and ordinary sentence punctuation;
 * nothing that formats or links. Latin only, so lookalike letters from other
 * scripts cannot spell a banned name past the checks.
 */
const PLAIN_TEXT = /^[\p{Script=Latin}0-9 .,;:!?'’"“”()\-–—/&]*$/u;
/** A scheme, `www.`, or any `name.tld`, so no domain gets through. */
const URL_LIKE = /(?:[a-z][a-z0-9+.-]*:\/\/|www\.|[a-z0-9-]\.[a-z]{2,}\b)/i;
const ONLY_N_LEFT = /\bonly\s+[0-9]+\s+(?:\p{L}+\s+)?left\b/iu;
/** A digit run and the word right after it (optionally hyphenated: `7-day`). */
const NUMBER_WITH_UNIT = /([0-9][0-9.,]*)(?:\s*-\s*|\s+)?([\p{L}]+(?:-[\p{L}]+)?)?/gu;
const PLAN_NAMES: Readonly<Record<string, FactPlan>> = { go: "go", pro: "pro", max: "max" };

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

/** The plans a sentence names, by their product names (Go, Pro, Max). */
function plansNamed(sentence: string): FactPlan[] {
  return [...sentence.matchAll(/\b(Go|Pro|Max)\b/g)].map((match) => PLAN_NAMES[match[1]!.toLowerCase()]!);
}

function quantityErrors(field: string, text: string, context: CopyContext): string[] {
  const errors: string[] = [];
  const extra = new Set(context.extraQuantities ?? []);
  for (const sentence of text.split(/[.;!?]\s+|[.;!?]$/)) {
    const plans = plansNamed(sentence);
    for (const match of sentence.matchAll(NUMBER_WITH_UNIT)) {
      const raw = match[1]!;
      if (!/^[0-9]+$/.test(raw)) {
        errors.push(`${field}: "${raw}" must be a whole number without separators`);
        continue;
      }
      const unit = match[2] ? UNIT_ALIASES[match[2].toLowerCase()] : undefined;
      if (!unit) {
        errors.push(`${field}: the number ${raw} needs a unit the facts state (VMs, vCPUs, GB, VM-hours)`);
        continue;
      }
      const quantity = `${Number(raw)} ${unit}`;
      if (extra.has(quantity)) continue;
      if (!FACT_QUANTITIES.has(quantity)) {
        errors.push(`${field}: "${match[0].trim()}" is not a published quantity`);
      } else if (plans.length > 0 && !plans.some((plan) => PLAN_FACT_QUANTITIES[plan].has(quantity))) {
        errors.push(`${field}: "${match[0].trim()}" is not a published quantity for ${plans.join(" or ")}`);
      }
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
  // "Free" is a price claim; only a variant that sells a free trial may say it.
  const mentionsTrial = containsPhrase(text, "trial") || containsPhrase(text, "free");
  if (!mentionsTrial) return [];
  const available = context.trialAvailable ?? FREE_TRIAL_AVAILABLE;
  if (available && context.offersTrial) return [];
  return [`${field}: "free" and trial wording need a variant that offers a trial product`];
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
  if (value.normalize("NFKC") !== value) errors.push(`${field}: must be in normalized form (NFKC)`);
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
  for (const word of NUMBER_WORDS) {
    if (containsPhrase(value, word)) errors.push(`${field}: write "${word}" as digits with a unit so it can be checked`);
  }
  errors.push(...unlimitedErrors(field, value), ...trialErrors(field, value, context), ...quantityErrors(field, value, context));
  return errors;
}

// The iOS paywall payload (contract with the iOS app).

/** Every layout the server knows. An app declares the ones it can draw (`x-cmux-paywall-layouts`). */
export const IOS_PAYWALL_LAYOUTS = ["cards", "comparison", "focus", "checklist", "planTabs", "hero", "trialTimeline", "specList"] as const;
/** What an app that sends no `x-cmux-paywall-layouts` header can draw. */
export const IOS_PAYWALL_BASE_LAYOUTS = ["cards", "comparison", "focus"] as const;
export type IosPaywallLayout = (typeof IOS_PAYWALL_LAYOUTS)[number];
/** `entry_point` values the app sends; `entryPointHeadlines` may override the headline for these. */
export const IOS_PAYWALL_ENTRY_POINTS = [
  "settings", "settings_upgrade_card", "cloud_banner", "cloud_new_machine", "locked_vm_size", "limit", "cloud_upgrade", "paywall_lab",
] as const;
export const IOS_PAYWALL_CTA_STYLES = ["price", "action"] as const;
export const IOS_PAYWALL_PLAN_IDS = ["pro", "max"] as const;
export const IOS_PAYWALL_BILLING_PERIODS = ["yearly", "monthly"] as const;

export type IosPaywallConfig = {
  readonly experiment: string;
  readonly variant: string;
  readonly layout: IosPaywallLayout;
  readonly headline: string;
  /**
   * Set by the server (never by a payload) when the served layout is
   * `specList`: the spec lines per plan, from facts.ts PLAN_SPECS.
   */
  readonly planSpecs?: Readonly<Record<"pro" | "max", readonly string[]>>;
  /** Optional headline per entry point, validated like `headline`. */
  readonly entryPointHeadlines?: Readonly<Record<string, string>>;
  /**
   * Server-only: the layout to use when this variant's layout cannot be
   * served (trialTimeline to a user who is not trial-eligible, or a layout
   * the app does not declare). Never sent to the app.
   */
  readonly fallbackLayout?: IosPaywallLayout;
  readonly subheadline: string;
  readonly bullets: readonly string[];
  readonly highlightedPlanId: (typeof IOS_PAYWALL_PLAN_IDS)[number] | null;
  /**
   * The period preselected for plans that offer both. Not a global toggle:
   * not every plan has a yearly product, so the app shows periods per plan.
   */
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

function layoutErrors(record: Record<string, unknown>): string[] {
  const errors: string[] = [];
  if (!oneOf(IOS_PAYWALL_LAYOUTS, record.layout)) errors.push(`layout: must be one of ${IOS_PAYWALL_LAYOUTS.join(", ")}`);
  if (record.fallbackLayout !== undefined && (!oneOf(IOS_PAYWALL_LAYOUTS, record.fallbackLayout) || record.fallbackLayout === "trialTimeline")) {
    errors.push("fallbackLayout: must be a layout other than trialTimeline");
  }
  if (record.layout === "trialTimeline" && record.fallbackLayout === undefined) {
    errors.push("fallbackLayout: required for trialTimeline (shown to users who cannot get the trial)");
  }
  return errors;
}

function entryPointShapeErrors(headlines: unknown): string[] {
  if (headlines === undefined) return [];
  return !headlines || typeof headlines !== "object" || Array.isArray(headlines) ? ["entryPointHeadlines: must be an object"] : [];
}

/**
 * The entry-point headlines that pass: an unknown entry point or a headline
 * that fails the copy rules is dropped on its own (the variant still serves
 * its main headline there), like the app does.
 */
function validEntryPointHeadlines(value: unknown, context: CopyContext): Record<string, string> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const valid = Object.entries(value).filter(([entryPoint, headline]) =>
    oneOf(IOS_PAYWALL_ENTRY_POINTS, entryPoint)
    && typeof headline === "string"
    && copyErrors(`entryPointHeadlines.${entryPoint}`, headline, { maxLength: 60, required: true }, context).length === 0);
  return valid.length > 0 ? Object.fromEntries(valid) as Record<string, string> : undefined;
}

function iosPaywallShapeErrors(record: Record<string, unknown>, experiment: string, variant: string): string[] {
  const errors: string[] = [];
  if (record.experiment !== undefined && record.experiment !== experiment) errors.push("experiment: does not match the flag");
  if (record.variant !== undefined && record.variant !== variant) errors.push("variant: does not match the flag variant");
  if (!VARIANT_KEY.test(variant)) errors.push("variant: must be a lowercase key");
  errors.push(...layoutErrors(record), ...entryPointShapeErrors(record.entryPointHeadlines));
  if (record.highlightedPlanId !== null && !oneOf(IOS_PAYWALL_PLAN_IDS, record.highlightedPlanId)) {
    errors.push("highlightedPlanId: must be pro, max or null");
  }
  if (!oneOf(IOS_PAYWALL_BILLING_PERIODS, record.defaultBillingPeriod)) errors.push("defaultBillingPeriod: must be yearly or monthly");
  if (!oneOf(IOS_PAYWALL_CTA_STYLES, record.ctaStyle)) errors.push("ctaStyle: must be price or action");
  if (typeof record.showYearlySavings !== "boolean") errors.push("showYearlySavings: must be a boolean");
  if (!Array.isArray(record.bullets) || record.bullets.length > 5) errors.push("bullets: must be a list of at most 5");
  const allowed = new Set([
    "experiment", "variant", "layout", "headline", "subheadline", "bullets",
    "highlightedPlanId", "defaultBillingPeriod", "ctaStyle", "showYearlySavings", "entryPointHeadlines", "fallbackLayout",
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
      ...withEntryPointHeadlines(validEntryPointHeadlines(record.entryPointHeadlines, context)),
      ...(record.fallbackLayout ? { fallbackLayout: record.fallbackLayout as IosPaywallLayout } : {}),
    },
  };
}

function withEntryPointHeadlines(headlines: Record<string, string> | undefined): { entryPointHeadlines?: Record<string, string> } {
  return headlines ? { entryPointHeadlines: headlines } : {};
}
