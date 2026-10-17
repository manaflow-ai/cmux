// The Paywall Lab: one staff view of every paywall and pricing experiment.
//
// It joins three sources and never computes statistics of its own:
// - the optimizer's stored runs and change log (staffVariantsView, store.ts),
//   which carry traffic, exposures, conversions, P(best), SRM and the daily
//   markdown report;
// - the live PostHog flag, for the kill-switch state (active or paused);
// - this repository's variant definitions, so each variant renders as users
//   see it (web: the real pricing components; iOS: the validated payload).

import { experimentDefinition, PAYWALL_EXPERIMENTS } from "../paywall/experiments";
import { FREE_TRIAL_AVAILABLE, PLAN_SPECS } from "../paywall/facts";
import type { OptimizerSnapshot } from "../paywall/optimizer";
import type { PaywallExperimentLog } from "../paywall/store";
import { staffVariantsView, type StaffVariantsView } from "../paywall/variantsView";
import type { IosPaywallConfig } from "../paywall/validator";
import {
  readExperimentFlag,
  setExperimentFlagActive,
  type ExperimentFlag,
  type FlagResult,
} from "./posthogFlagAdmin";
import { WEB_PRICING_V1_VARIANTS, type WebPricingPresentation } from "./webPricingV1";
import { isVaultEnabled } from "../../vault/config";

export type LabFlagState = "live" | "paused" | "missing" | "unavailable" | "unconfigured";

export type LabVariantPreview =
  | { readonly kind: "web"; readonly presentation: WebPricingPresentation }
  | { readonly kind: "ios"; readonly config: IosPaywallConfig };

export type LabVariant = {
  readonly variant: string;
  readonly name: string | null;
  readonly hypothesis: string | null;
  /** `queued`: a challenger at 0% that the optimizer promotes when a live arm retires. */
  readonly status: "live" | "retired" | "queued";
  readonly trafficPercent: number;
  readonly proposedTrafficPercent: number | null;
  readonly exposures: number | null;
  readonly conversions: number | null;
  readonly probabilityBest: number | null;
  readonly secondary: Readonly<Record<string, number>>;
  readonly guardrails: Readonly<Record<string, number>>;
  readonly payloadErrors: readonly string[];
  /** Null when the copy fails validation: users of this arm see control. */
  readonly preview: LabVariantPreview | null;
};

export type LabExperiment = {
  readonly key: string;
  readonly platform: string;
  readonly controlVariant: string;
  readonly flagState: LabFlagState;
  readonly source: StaffVariantsView["source"];
  readonly lastRunAt: string | null;
  readonly halted: boolean;
  readonly reasons: readonly string[];
  readonly hasReport: boolean;
  readonly srm: { readonly tested: boolean; readonly pValue: number | null; readonly mismatch: boolean; readonly note: string | null };
  readonly allocationSince: string | null;
  readonly primaryLabel: string;
  readonly secondaryMetrics: readonly { readonly key: string; readonly label: string }[];
  readonly guardrailMetrics: readonly { readonly key: string; readonly label: string }[];
  readonly variants: readonly LabVariant[];
  readonly changeLog: StaffVariantsView["changeLog"];
};

export type PaywallLabView = {
  readonly generatedAt: string;
  readonly trialAvailable: boolean;
  /** Whether /pricing lists the Vault features, so web previews match it. */
  readonly vaultEnabled: boolean;
  readonly experiments: readonly LabExperiment[];
};

type Dependencies = {
  readonly log: PaywallExperimentLog;
  readonly readFlag?: (key: string) => Promise<FlagResult<ExperimentFlag>>;
  readonly now?: () => Date;
  readonly vaultEnabled?: () => boolean;
};

function flagState(result: FlagResult<ExperimentFlag>): LabFlagState {
  if (result.ok) return result.value.active ? "live" : "paused";
  return result.error === "not_found" ? "missing" : result.error;
}

function srmSummary(snapshot: OptimizerSnapshot | null): LabExperiment["srm"] {
  const srm = snapshot?.decision?.srm;
  if (!srm) return { tested: false, pValue: null, mismatch: false, note: "no optimizer run yet" };
  if (!srm.tested) return { tested: false, pValue: null, mismatch: false, note: srm.reason };
  return { tested: true, pValue: Number.isFinite(srm.pValue) ? srm.pValue : 0, mismatch: srm.mismatch, note: null };
}

function preview(platform: string, paywall: unknown): LabVariantPreview | null {
  if (!paywall) return null;
  if (platform === "web") return { kind: "web", presentation: paywall as WebPricingPresentation };
  const config = paywall as IosPaywallConfig;
  // The server adds the plan specs when it serves specList (iosPaywall.ts
  // servedPaywallConfig); the validated payload has none, so add them here too.
  return { kind: "ios", config: config.layout === "specList" ? { ...config, planSpecs: PLAN_SPECS } : config };
}

const STATUS_RANK = { live: 0, queued: 1, retired: 2 } as const;

/**
 * Live arms, then the challenger queue in the order the optimizer promotes it
 * (the definition's `queue`), then retired arms.
 */
function inLabOrder<T extends { readonly variant: string; readonly status: keyof typeof STATUS_RANK }>(
  variants: readonly T[],
  queue: readonly string[],
): T[] {
  const position = (variant: string) => {
    const index = queue.indexOf(variant);
    return index === -1 ? queue.length : index;
  };
  return [...variants].sort((a, b) =>
    STATUS_RANK[a.status] - STATUS_RANK[b.status]
    || (a.status === "queued" ? position(a.variant) - position(b.variant) : 0));
}

async function labExperiment(key: string, deps: Dependencies): Promise<LabExperiment | null> {
  const definition = experimentDefinition(key);
  if (!definition) return null;
  const [view, run, flag] = await Promise.all([
    staffVariantsView(key, deps.log),
    deps.log.latestRun(key),
    (deps.readFlag ?? readExperimentFlag)(definition.flagKey),
  ]);
  if (!view) return null;
  const snapshot = (run?.snapshot ?? null) as OptimizerSnapshot | null;
  const counts = new Map((snapshot?.variants ?? []).map((variant) => [variant.variant, variant]));
  const hypotheses = new Map(WEB_PRICING_V1_VARIANTS.map((variant) => [variant.key, variant.hypothesis]));
  return {
    key,
    platform: definition.platform,
    controlVariant: definition.controlVariant,
    flagState: flagState(flag),
    source: view.source,
    lastRunAt: view.lastRunAt,
    halted: view.halted,
    reasons: view.reasons,
    hasReport: Boolean(view.reportMarkdown),
    srm: srmSummary(snapshot),
    allocationSince: snapshot?.allocationSince ?? null,
    primaryLabel: definition.primary.label,
    secondaryMetrics: definition.secondary.map(({ key: metric, label }) => ({ key: metric, label })),
    guardrailMetrics: definition.guardrails.map(({ key: metric, label }) => ({ key: metric, label })),
    variants: inLabOrder(view.variants, definition.queue ?? []).map((variant) => ({
      variant: variant.variant,
      name: variant.name,
      hypothesis: definition.platform === "web" ? hypotheses.get(variant.variant) ?? null : null,
      status: variant.status,
      trafficPercent: variant.trafficPercent,
      proposedTrafficPercent: variant.proposedTrafficPercent,
      exposures: variant.exposures,
      conversions: variant.conversions,
      probabilityBest: variant.probabilityBest,
      secondary: counts.get(variant.variant)?.secondary ?? {},
      guardrails: counts.get(variant.variant)?.guardrails ?? {},
      payloadErrors: variant.payloadErrors,
      preview: preview(definition.platform, variant.paywall),
    })),
    changeLog: view.changeLog,
  };
}

export async function paywallLabView(deps: Dependencies): Promise<PaywallLabView> {
  const experiments = await Promise.all(PAYWALL_EXPERIMENTS.map((definition) => labExperiment(definition.key, deps)));
  return {
    generatedAt: (deps.now ?? (() => new Date()))().toISOString(),
    trialAvailable: FREE_TRIAL_AVAILABLE,
    vaultEnabled: (deps.vaultEnabled ?? isVaultEnabled)(),
    experiments: experiments.filter((experiment): experiment is LabExperiment => experiment !== null),
  };
}

/** The stored daily report of the newest optimizer run, or null. */
export async function latestPaywallReport(key: string, log: PaywallExperimentLog): Promise<{ readonly ranAt: Date; readonly markdown: string } | null> {
  if (!experimentDefinition(key)) return null;
  const run = await log.latestRun(key);
  return run?.reportMarkdown ? { ranAt: run.ranAt, markdown: run.reportMarkdown } : null;
}

export type KillSwitchResult =
  | { readonly ok: true; readonly flagState: "live" | "paused" }
  | { readonly ok: false; readonly error: "unknown_experiment" | "unconfigured" | "not_found" | "unavailable" };

/**
 * The kill switch. Pausing turns the experiment's flag off, so every arm is
 * served control (web within a minute, through the proxy's flag cache);
 * resuming turns it back on with the split untouched. Each use is written to
 * the change log as an allocation change with the staff member who did it.
 * The optimizer holds traffic while the flag is off.
 */
export async function setExperimentPaused(input: {
  readonly experiment: string;
  readonly paused: boolean;
  readonly actorEmail: string | null;
  readonly log: Pick<PaywallExperimentLog, "appendChanges">;
  readonly readFlag?: (key: string) => Promise<FlagResult<ExperimentFlag>>;
  readonly setActive?: (flag: ExperimentFlag, active: boolean) => Promise<FlagResult<null>>;
}): Promise<KillSwitchResult> {
  const definition = experimentDefinition(input.experiment);
  if (!definition) return { ok: false, error: "unknown_experiment" };
  const flag = await (input.readFlag ?? readExperimentFlag)(definition.flagKey);
  if (!flag.ok) return flag;
  const written = await (input.setActive ?? ((target, active) => setExperimentFlagActive(target, active)))(flag.value, !input.paused);
  if (!written.ok) return written;
  const actor = `staff:${input.actorEmail ?? "unknown"}`;
  await input.log.appendChanges([{
    experiment: definition.key,
    kind: "allocation_changed",
    variant: null,
    reason: input.paused
      ? `kill switch: paused by ${input.actorEmail ?? "staff"}; every visitor gets ${definition.controlVariant}`
      : `kill switch: resumed by ${input.actorEmail ?? "staff"}; the flag's split applies again`,
    details: {
      paused: input.paused,
      split: Object.fromEntries(flag.value.variants.map((variant) => [variant.key, variant.rolloutPercentage])),
    },
    actor,
  }]);
  return { ok: true, flagState: input.paused ? "paused" : "live" };
}
