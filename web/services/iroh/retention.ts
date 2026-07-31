// Hourly Iroh retention cron orchestration: the existing global retention
// drain, then the stale-binding reaper, then a best-effort presence nudge for
// every reaped binding (same wake-up hook the user revoke and reincarnation
// paths fire). Lives outside the Next.js route file so it can be unit-tested
// with stub repositories; the route stays a thin auth wrapper.

import * as Effect from "effect/Effect";
import { env } from "../../app/env";
import {
  IROH_RETENTION_MAX_DURATION_MS,
  IROH_RETENTION_MAX_ROWS,
  type IrohRepositoryShape,
  type IrohRetentionResult,
} from "./repository";
import { irohPresenceNudgeLive, type IrohPresenceNudgeShape } from "./presenceNudge";

export const IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT = 72;
export const IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT = 45 * 24;
const MAX_STALE_BINDING_TTL_HOURS = 24 * 366;

export type IrohStaleBindingTtls = {
  readonly devHours: number;
  readonly releaseHours: number;
};

/** Env-tunable reap TTLs with safe defaults. Invalid or out-of-range values
 * fall back to the defaults rather than failing the cron. Pure for tests. */
export function irohStaleBindingTtlHours(
  raw: { readonly dev?: string; readonly release?: string } = {
    dev: env.CMUX_IROH_STALE_DEV_BINDING_TTL_HOURS,
    release: env.CMUX_IROH_STALE_RELEASE_BINDING_TTL_HOURS,
  },
): IrohStaleBindingTtls {
  return {
    devHours: boundedTtlHours(raw.dev, IROH_STALE_DEV_BINDING_TTL_HOURS_DEFAULT),
    releaseHours: boundedTtlHours(raw.release, IROH_STALE_RELEASE_BINDING_TTL_HOURS_DEFAULT),
  };
}

function boundedTtlHours(value: string | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= MAX_STALE_BINDING_TTL_HOURS
    ? parsed
    : fallback;
}

export type IrohRetentionRunSummary = {
  readonly retention: IrohRetentionResult;
  readonly reap: {
    readonly revoked: number;
    readonly candidates: number;
    readonly skippedUsers: number;
    readonly backlog: boolean;
    readonly devCutoff: string;
    readonly releaseCutoff: string;
  };
};

export function runIrohRetention(input: {
  readonly repository: IrohRepositoryShape;
  readonly now?: Date;
  readonly presenceNudge?: IrohPresenceNudgeShape;
  readonly ttlHours?: IrohStaleBindingTtls;
}) {
  return Effect.gen(function* () {
    const now = input.now ?? new Date();
    const presenceNudge = input.presenceNudge ?? irohPresenceNudgeLive;
    const { devHours, releaseHours } = input.ttlHours ?? irohStaleBindingTtlHours();

    const retention = yield* input.repository.pruneExpiredStateGlobally({
      now,
      maxRows: IROH_RETENTION_MAX_ROWS,
      maxDurationMs: IROH_RETENTION_MAX_DURATION_MS,
    });

    const devCutoff = new Date(now.getTime() - devHours * 60 * 60 * 1_000);
    const releaseCutoff = new Date(now.getTime() - releaseHours * 60 * 60 * 1_000);
    const reap = yield* input.repository.reapStaleBindings({
      now,
      devCutoff,
      releaseCutoff,
    });

    if (reap.revoked.length > 0) {
      // Reaped devices re-register in place on next launch (newest-wins slot
      // re-key); a still-running instance learns within seconds through its
      // directed nudge channel instead of at its next poll. Best-effort and
      // defect-guarded: nudge delivery can never fail the cron.
      yield* Effect.suspend(() => presenceNudge.bindingChanged(
        reap.revoked.map((binding) => ({
          userId: binding.userId,
          deviceUuid: binding.deviceUuid,
          tag: binding.tag,
        })),
      )).pipe(Effect.catchAllCause(() => Effect.void));
    }

    const summary: IrohRetentionRunSummary = {
      retention,
      reap: {
        revoked: reap.revoked.length,
        candidates: reap.candidates,
        skippedUsers: reap.skippedUsers,
        backlog: reap.backlog,
        devCutoff: devCutoff.toISOString(),
        releaseCutoff: releaseCutoff.toISOString(),
      },
    };
    return summary;
  });
}
