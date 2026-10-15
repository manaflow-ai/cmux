// The staff view of an experiment: every live and retired variant with its
// copy, traffic share and counts from the latest optimizer run, plus the
// change log. Before the first run it shows the seed definition.

import { experimentDefinition } from "./experiments";
import type { OptimizerSnapshot } from "./optimizer";
import { SEED_FLAGS } from "./runAll";
import type { PaywallExperimentLog } from "./store";

export type StaffVariant = {
  readonly experiment: string;
  readonly platform: string;
  readonly variant: string;
  readonly name: string | null;
  readonly status: "live" | "retired" | "queued";
  /** The validated payload (for iOS, the paywall object the app renders); null when it fails validation. */
  readonly paywall: unknown;
  readonly payloadErrors: readonly string[];
  readonly trafficPercent: number;
  readonly proposedTrafficPercent: number | null;
  readonly exposures: number | null;
  readonly conversions: number | null;
  readonly probabilityBest: number | null;
};

export type StaffVariantsView = {
  readonly experiment: string;
  readonly platform: string;
  readonly source: "optimizer_run" | "seed";
  readonly lastRunAt: string | null;
  readonly halted: boolean;
  readonly reasons: readonly string[];
  readonly reportMarkdown: string | null;
  readonly variants: readonly StaffVariant[];
  readonly changeLog: readonly {
    readonly changedAt: string;
    readonly kind: string;
    readonly variant: string | null;
    readonly reason: string;
    readonly actor: string;
    readonly details: Record<string, unknown> | null;
  }[];
};

export async function staffVariantsView(experimentKey: string, log: PaywallExperimentLog): Promise<StaffVariantsView | null> {
  const definition = experimentDefinition(experimentKey);
  if (!definition) return null;
  const [run, changes] = await Promise.all([log.latestRun(definition.key), log.changes(definition.key, 200)]);
  const changeLog = changes.map((change) => ({
    changedAt: change.changedAt.toISOString(),
    kind: change.kind,
    variant: change.variant,
    reason: change.reason,
    actor: change.actor,
    details: change.details,
  }));
  const validated = (payload: unknown, variant: string) => {
    const result = definition.validatePayload(payload, variant);
    return result.ok ? { paywall: result.value, payloadErrors: [] } : { paywall: null, payloadErrors: result.errors };
  };
  if (run) {
    const snapshot = run.snapshot as OptimizerSnapshot;
    // An observe-mode run proposes a split it did not write; the flag still has the old one.
    const applied = snapshot.allocationApplied || !snapshot.decision.changed;
    return {
      experiment: definition.key,
      platform: definition.platform,
      source: "optimizer_run",
      lastRunAt: run.ranAt.toISOString(),
      halted: run.halted,
      reasons: snapshot.decision.reasons,
      reportMarkdown: run.reportMarkdown,
      variants: snapshot.variants.map((variant) => ({
        experiment: definition.key,
        platform: definition.platform,
        variant: variant.variant,
        name: variant.name,
        status: (applied ? variant.rolloutAfter : variant.rolloutBefore) > 0 ? "live" : variant.status === "retired" ? "retired" : "queued",
        ...validated(variant.payload, variant.variant),
        trafficPercent: applied ? variant.rolloutAfter : variant.rolloutBefore,
        proposedTrafficPercent: applied ? null : variant.rolloutAfter,
        exposures: variant.exposures,
        conversions: variant.conversions,
        probabilityBest: variant.probabilityBest,
      })),
      changeLog,
    };
  }
  const seed = SEED_FLAGS[definition.key]?.();
  return {
    experiment: definition.key,
    platform: definition.platform,
    source: "seed",
    lastRunAt: null,
    halted: false,
    reasons: [],
    reportMarkdown: null,
    variants: (seed?.variants ?? []).map((variant) => {
      const raw = seed?.payloads[variant.key];
      return {
        experiment: definition.key,
        platform: definition.platform,
        variant: variant.key,
        name: variant.name ?? null,
        status: variant.rolloutPercentage > 0 ? "live" : "queued",
        ...validated(typeof raw === "string" ? JSON.parse(raw) : raw, variant.key),
        trafficPercent: variant.rolloutPercentage,
        proposedTrafficPercent: null,
        exposures: null,
        conversions: null,
        probabilityBest: null,
      };
    }),
    changeLog,
  };
}
