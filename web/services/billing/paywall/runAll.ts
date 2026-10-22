// Runs the optimizer for every registered experiment. Shared by the daily
// cron route and scripts/paywall-optimizer/run.ts.

import { PAYWALL_EXPERIMENTS, type ExperimentDefinition } from "./experiments";
import { iosPaywallV1FlagDefinition, IOS_PAYWALL_EXPERIMENT } from "./iosPaywallV1";
import { postHogApi, runOptimizer, seedFlag, type OptimizerRunResult, type PostHogApi, type PostHogFlag } from "./optimizer";
import type { PaywallExperimentLog } from "./store";

/** Seed flags by experiment, for dry runs before a flag is created. */
export const SEED_FLAGS: Readonly<Record<string, () => PostHogFlag>> = {
  [IOS_PAYWALL_EXPERIMENT]: () => seedFlag(iosPaywallV1FlagDefinition()),
};

export const POSTHOG_PROJECT_ID_DEFAULT = "244066";

export function optimizerPostHogApi(env: Record<string, string | undefined>): PostHogApi | null {
  const personalApiKey = env.POSTHOG_PERSONAL_API_KEY?.trim();
  if (!personalApiKey) return null;
  return postHogApi({
    personalApiKey,
    projectId: env.POSTHOG_PROJECT_ID?.trim() || POSTHOG_PROJECT_ID_DEFAULT,
    host: env.POSTHOG_API_HOST?.trim() || undefined,
  });
}

export type ExperimentRunOutcome =
  | { readonly experiment: string; readonly ok: true; readonly result: OptimizerRunResult }
  | { readonly experiment: string; readonly ok: false; readonly error: string };

export async function runAllOptimizers(input: {
  readonly api: PostHogApi;
  readonly log: PaywallExperimentLog | null;
  readonly dryRun: boolean;
  readonly now: Date;
  readonly actor: string;
  readonly applyAllocation?: boolean;
  readonly experiments?: readonly ExperimentDefinition[];
}): Promise<ExperimentRunOutcome[]> {
  const outcomes: ExperimentRunOutcome[] = [];
  for (const definition of input.experiments ?? PAYWALL_EXPERIMENTS) {
    try {
      const result = await runOptimizer({
        definition,
        api: input.api,
        log: input.log,
        dryRun: input.dryRun,
        now: input.now,
        seedFlag: SEED_FLAGS[definition.key]?.(),
        actor: input.actor,
        applyAllocation: input.applyAllocation,
      });
      outcomes.push({ experiment: definition.key, ok: true, result });
    } catch (error) {
      // One broken experiment must not stop the others.
      outcomes.push({ experiment: definition.key, ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return outcomes;
}
