import { and, eq, or } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import type { cloudDb } from "../../db/client";
import { deviceTokens } from "../../db/schema";
import { AccountDeletionMutationBlockedError } from "../account/deletionLock";
import {
  completePushSend,
  recordPushSendOrThrow,
  releasePushSendLease,
  PushCorrelationConflictError,
  PushRateLimitExceededError,
  type PushSendRecord,
} from "./rateLimit";
import {
  clampRetryToEventLife,
  mergePushDeliveryOutcomes,
  unresolvedPushTargets,
} from "./deliveryState";
import type { PushPayload } from "./routePolicy";
import {
  type ApnsConfig,
  type ApnsSendResult,
  type ApnsTarget,
  isTransientApnsResult,
  sendApnsNotificationReliably,
} from "./sender";
import {
  summarizeApnsSendResults,
  type PushSendSummary,
} from "./response";
import {
  claimDeviceDeliveryTargets,
  type DeviceDeliveryClaim,
  DeviceDeliveryBusyError,
  withAuthorizedDeviceDeliveryTargets,
  releaseDeviceDeliveryTargets,
} from "./deviceDeliveryLease";

type PushDatabase = ReturnType<typeof cloudDb>;

export type PushDeliveryPayload = PushPayload & {
  readonly correlationId: string;
  readonly expirationEpochSeconds: number;
};

export interface PushDeliveryInput {
  readonly userId: string;
  /** Bundle to deliver to, or null for the legacy account-wide fan-out. */
  readonly targetBundleId: string | null;
  readonly correlationId: string;
  readonly payloadFingerprint: string;
  readonly startedAt: Date;
  readonly expirationEpochSeconds: number;
  readonly payload: PushDeliveryPayload;
}

export interface PushDeliveryOutcome {
  readonly summary: PushSendSummary;
  readonly replayed: boolean;
}

export class PushDeliveryInProgressError extends Data.TaggedError(
  "PushDeliveryInProgressError",
)<{
  readonly correlationId: string;
  readonly retryAfterSeconds: number;
}> {}

export class PushDeliveryCorrelationConflictError extends Data.TaggedError(
  "PushDeliveryCorrelationConflictError",
)<{
  readonly correlationId: string;
}> {}

export class PushDeliveryRateLimitedError extends Data.TaggedError(
  "PushDeliveryRateLimitedError",
)<{
  readonly retryAfterSeconds: number;
}> {}

export class PushDeliveryConfigurationError extends Data.TaggedError(
  "PushDeliveryConfigurationError",
)<{
  readonly code: "push_service_not_configured";
}> {}

export class PushDeliveryAccountDeletionInProgressError extends Data.TaggedError(
  "PushDeliveryAccountDeletionInProgressError",
)<Record<string, never>> {}

export type PushDeliveryError =
  | PushDeliveryInProgressError
  | PushDeliveryCorrelationConflictError
  | PushDeliveryRateLimitedError
  | PushDeliveryConfigurationError
  | PushDeliveryAccountDeletionInProgressError;

export interface PushDeliveryServiceShape {
  readonly deliver: (
    input: PushDeliveryInput,
  ) => Effect.Effect<PushDeliveryOutcome, PushDeliveryError>;
}

export class PushDeliveryService extends Context.Tag(
  "cmux/PushDeliveryService",
)<PushDeliveryService, PushDeliveryServiceShape>() {}

export interface PushDeliveryDependencies {
  readonly db: PushDatabase;
  readonly config: ApnsConfig | null;
  readonly send?: typeof sendApnsNotificationReliably;
  readonly recordOutcome: (
    summary: PushSendSummary,
    correlationId: string,
  ) => void;
}

type DeliveryExecution =
  | {
      readonly ok: true;
      readonly outcome: PushDeliveryOutcome;
    }
  | {
      readonly ok: false;
      readonly error: PushDeliveryError;
    };

export function makePushDeliveryService(
  dependencies: PushDeliveryDependencies,
): PushDeliveryServiceShape {
  return {
    deliver: (input) =>
      Effect.promise(() => executePushDelivery(input, dependencies)).pipe(
        Effect.flatMap((result) =>
          result.ok
            ? Effect.succeed(result.outcome)
            : Effect.fail(result.error)
        ),
      ),
  };
}

async function executePushDelivery(
  input: PushDeliveryInput,
  dependencies: PushDeliveryDependencies,
): Promise<DeliveryExecution> {
  const { db } = dependencies;
  let deviceClaim: DeviceDeliveryClaim;
  try {
    deviceClaim = await claimDeviceDeliveryTargets(
      db,
      input.userId,
      input.targetBundleId,
      input.startedAt,
    );
  } catch (error) {
    if (error instanceof DeviceDeliveryBusyError) {
      return {
        ok: false,
        error: new PushDeliveryInProgressError({
          correlationId: input.correlationId,
          retryAfterSeconds: error.retryAfterSeconds,
        }),
      };
    }
    if (error instanceof AccountDeletionMutationBlockedError) {
      return {
        ok: false,
        error: new PushDeliveryAccountDeletionInProgressError({}),
      };
    }
    throw error;
  }

  try {
    return await executePushDeliveryWithTargets(
      input,
      dependencies,
      [...deviceClaim.targets],
      deviceClaim.leaseToken,
    );
  } finally {
    await releaseDeviceDeliveryTargets(
      db,
      deviceClaim.leaseToken,
      deviceClaim.targets.flatMap((target) =>
        target.targetId == null ? [] : [target.targetId]
      ),
    );
  }
}

async function executePushDeliveryWithTargets(
  input: PushDeliveryInput,
  dependencies: PushDeliveryDependencies,
  tokens: ApnsTarget[],
  deviceLeaseToken: string | null,
): Promise<DeliveryExecution> {
  const { db } = dependencies;
  const preparation = await preparePushDelivery(
    input,
    dependencies,
    tokens,
  );
  if (preparation.kind === "done") return preparation.execution;
  if (preparation.kind === "error") {
    return { ok: false, error: preparation.error };
  }
  const {
    deliveryPayload,
    leaseToken,
    priorOutcomes: preparedOutcomes,
    sendTargets: preparedTargets,
  } = preparation;
  let priorOutcomes = preparedOutcomes;
  let sendTargets = preparedTargets;

  if (sendTargets.length === 0) {
    return await completeDelivery(
      dependencies,
      input,
      leaseToken,
      priorOutcomes,
      false,
      deliveryPayload.expirationEpochSeconds,
    );
  }
  if (!dependencies.config) {
    if (leaseToken) {
      await releasePushSendLease(
        db,
        input.userId,
        input.correlationId,
        leaseToken,
      );
    }
    return {
      ok: false,
      error: new PushDeliveryConfigurationError({
        code: "push_service_not_configured",
      }),
    };
  }

  const authorizedDelivery = await sendAuthorizedPushDelivery(
    db,
    input.userId,
    deviceLeaseToken,
    sendTargets,
    dependencies.config,
    dependencies.send ?? sendApnsNotificationReliably,
    deliveryPayload,
  );
  priorOutcomes = mergePushDeliveryOutcomes(
    priorOutcomes,
    authorizedDelivery.revokedOutcomes,
  );
  sendTargets = authorizedDelivery.sendTargets;
  if (sendTargets.length === 0) {
    return await completeDelivery(
      dependencies,
      input,
      leaseToken,
      priorOutcomes,
      false,
      deliveryPayload.expirationEpochSeconds,
    );
  }

  // Deliberately not tied to the caller's request lifecycle: a client
  // disconnect mid-send would discard partial APNs outcomes and re-alert
  // already-delivered devices on the next same-correlation retry, and it
  // would strand the correlation lease until it times out. The send is
  // bounded (attempt cap x timeout), so it always finishes inside the lease.
  const results = authorizedDelivery.results;
  const persistedResults = await persistApnsResults(
    db,
    input.userId,
    sendTargets,
    results,
  );

  return await completeDelivery(
    dependencies,
    input,
    leaseToken,
    mergePushDeliveryOutcomes(priorOutcomes, persistedResults),
    false,
    deliveryPayload.expirationEpochSeconds,
  );
}

type PushDeliveryPreparation =
  | {
      readonly kind: "ready";
      readonly deliveryPayload: PushDeliveryPayload;
      readonly leaseToken: string;
      readonly priorOutcomes: ApnsSendResult[];
      readonly sendTargets: ApnsTarget[];
    }
  | { readonly kind: "done"; readonly execution: DeliveryExecution }
  | { readonly kind: "error"; readonly error: PushDeliveryError };

async function preparePushDelivery(
  input: PushDeliveryInput,
  dependencies: PushDeliveryDependencies,
  tokens: ApnsTarget[],
): Promise<PushDeliveryPreparation> {
  const { db } = dependencies;
  try {
    const claim = await recordPushSendOrThrow(
      db,
      input.userId,
      tokens.length,
      input.correlationId,
      input.startedAt,
      new Date(input.expirationEpochSeconds * 1_000),
      input.payload.kind,
      tokens,
      input.payloadFingerprint,
    );
    if (claim.kind === "busy") {
      return {
        kind: "error",
        error: new PushDeliveryInProgressError({
          correlationId: input.correlationId,
          retryAfterSeconds: claim.retryAfterSeconds,
        }),
      };
    }
    const existing = claim.previous;
    const deliveryPayload = existing?.expiresAt
      ? {
          ...input.payload,
          expirationEpochSeconds: Math.floor(
            existing.expiresAt.getTime() / 1_000,
          ),
        }
      : input.payload;
    const replay = await replayCompletedPushDelivery(
      input,
      dependencies,
      claim.leaseToken,
      existing,
    );
    if (replay) return { kind: "done", execution: replay };
    const continuation = continuePushDelivery(
      tokens,
      existing,
    );
    if (continuation.sendTargets.length === 0) {
      return {
        kind: "done",
        execution: await completeDelivery(
          dependencies,
          input,
          claim.leaseToken,
          continuation.priorOutcomes,
          true,
          deliveryPayload.expirationEpochSeconds,
        ),
      };
    }
    return {
      kind: "ready",
      deliveryPayload,
      leaseToken: claim.leaseToken,
      priorOutcomes: continuation.priorOutcomes,
      sendTargets: continuation.sendTargets,
    };
  } catch (error) {
    if (error instanceof PushCorrelationConflictError) {
      return {
        kind: "error",
        error: new PushDeliveryCorrelationConflictError({
          correlationId: input.correlationId,
        }),
      };
    }
    if (error instanceof PushRateLimitExceededError) {
      return {
        kind: "error",
        error: new PushDeliveryRateLimitedError({
          retryAfterSeconds: error.retryAfterSeconds,
        }),
      };
    }
    throw error;
  }
}

async function replayCompletedPushDelivery(
  input: PushDeliveryInput,
  dependencies: PushDeliveryDependencies,
  leaseToken: string,
  existing: PushSendRecord | null,
): Promise<DeliveryExecution | null> {
  if (!existing?.summary) return null;
  const isExpired = existing.expiresAt != null
    && existing.expiresAt.getTime() <= input.startedAt.getTime();
  if (existing.summary.transientFailures !== 0 && !isExpired) return null;
  const replayOutcomes = isExpired && existing.summary.transientFailures > 0
    ? finalizeExpiredOutcomes(existing.outcomes)
    : existing.outcomes;
  const replaySummary = isExpired && existing.summary.transientFailures > 0
    ? summarizeExpiredRecord(existing.summary, replayOutcomes)
    : existing.summary;
  const completed = await completePushSend(
    dependencies.db,
    input.userId,
    input.correlationId,
    leaseToken,
    replaySummary,
    replayOutcomes,
    undefined,
    existing.expiresAt,
  );
  if (!completed) {
    return {
      ok: false,
      error: new PushDeliveryInProgressError({
        correlationId: input.correlationId,
        retryAfterSeconds: 1,
      }),
    };
  }
  dependencies.recordOutcome(replaySummary, input.correlationId);
  return {
    ok: true,
    outcome: {
      summary: replaySummary,
      replayed: true,
    },
  };
}

function continuePushDelivery(
  tokens: readonly ApnsTarget[],
  existing: PushSendRecord | null,
): { priorOutcomes: ApnsSendResult[]; sendTargets: ApnsTarget[] } {
  if (!existing) return { priorOutcomes: [], sendTargets: [...tokens] };
  const priorOutcomes = [...existing.outcomes];
  const currentByIdentity = new Map(
    tokens.map((target) => [targetIdentity(target), target]),
  );
  const originalTargets = existing.initialTargets ?? tokens;
  const unresolvedOriginalTargets = unresolvedPushTargets(
    originalTargets,
    priorOutcomes,
  );
  const removedOutcomes = unresolvedOriginalTargets
    .filter((target) => !currentByIdentity.has(targetIdentity(target)))
    .map((target): ApnsSendResult => ({
      targetId: target.targetId,
      deviceToken: target.deviceToken,
      status: 404,
      reason: "target_no_longer_registered",
      prune: false,
    }));
  const mergedOutcomes = mergePushDeliveryOutcomes(
    priorOutcomes,
    removedOutcomes,
  );
  const stillRegisteredOriginalTargets = originalTargets.flatMap((target) => {
    const current = currentByIdentity.get(targetIdentity(target));
    return current ? [current] : [];
  });
  return {
    priorOutcomes: mergedOutcomes,
    sendTargets: unresolvedPushTargets(
      stillRegisteredOriginalTargets,
      mergedOutcomes,
    ),
  };
}

async function sendAuthorizedPushDelivery(
  db: PushDatabase,
  userId: string,
  deviceLeaseToken: string | null,
  targets: readonly ApnsTarget[],
  config: ApnsConfig,
  send: typeof sendApnsNotificationReliably,
  payload: PushDeliveryPayload,
): Promise<{
  readonly sendTargets: ApnsTarget[];
  readonly revokedOutcomes: ApnsSendResult[];
  readonly results: Array<ApnsSendResult & { targetId?: string }>;
}> {
  const authorizedDelivery = await withAuthorizedDeviceDeliveryTargets(
    db,
    userId,
    deviceLeaseToken,
    targets,
    (authorizedTargets) => send(config, authorizedTargets, payload),
  );
  const authorizedTargetIDs = new Set(
    authorizedDelivery.authorizedTargets.flatMap((target) =>
      target.targetId == null ? [] : [target.targetId]
    ),
  );
  const revokedOutcomes = targets
    .filter((target) => target.targetId == null || !authorizedTargetIDs.has(target.targetId))
    .map((target): ApnsSendResult => ({
      targetId: target.targetId,
      deviceToken: target.deviceToken,
      status: 404,
      reason: "target_revoked",
      prune: false,
    }));
  const sendTargets = authorizedDelivery.authorizedTargets;
  const sentTargetByToken = new Map(
    sendTargets.map((target) => [target.deviceToken, target]),
  );
  const results = (authorizedDelivery.result ?? []).map((result) => ({
    ...result,
    targetId:
      result.targetId
      ?? sentTargetByToken.get(result.deviceToken)?.targetId,
  }));
  return { sendTargets, revokedOutcomes, results };
}

async function persistApnsResults(
  db: PushDatabase,
  userId: string,
  sendTargets: readonly ApnsTarget[],
  results: readonly (ApnsSendResult & { targetId?: string })[],
): Promise<Array<ApnsSendResult & { targetId?: string }>> {
  const targetsByID = new Map(
    sendTargets.flatMap((target) =>
      target.targetId == null ? [] : [[target.targetId, target] as const]
    ),
  );
  const deadTargets = results.flatMap((result) => {
    if (!result.prune || result.targetId == null) return [];
    const target = targetsByID.get(result.targetId);
    return target ? [{ ...target, targetId: result.targetId }] : [];
  });
  const exactDeadTargetPredicate = or(
    ...deadTargets.map((target) => and(
      eq(deviceTokens.id, target.targetId),
      eq(deviceTokens.deviceToken, target.deviceToken),
      eq(deviceTokens.bundleId, target.bundleId),
      eq(deviceTokens.environment, target.environment),
    )),
  );
  const deletedTargetIDs = new Set<string>();
  if (exactDeadTargetPredicate) {
    const deletedTargets = await db
      .delete(deviceTokens)
      .where(and(
        eq(deviceTokens.userId, userId),
        eq(deviceTokens.platform, "ios"),
        exactDeadTargetPredicate,
      ))
      .returning({ targetId: deviceTokens.id });
    for (const target of deletedTargets) deletedTargetIDs.add(target.targetId);
  }
  return results.map((result) => {
    if (!result.prune || (
      result.targetId != null && deletedTargetIDs.has(result.targetId)
    )) return result;
    return { ...result, prune: false };
  });
}

function finalizeExpiredOutcomes(
  outcomes: readonly ApnsSendResult[],
): ApnsSendResult[] {
  return outcomes.map((outcome) => {
    if (!isTransientApnsResult(outcome)) return outcome;
    return {
      ...(outcome.targetId == null ? {} : { targetId: outcome.targetId }),
      deviceToken: outcome.deviceToken,
      status: 0,
      reason: "event_expired",
      prune: false,
    };
  });
}

function summarizeExpiredRecord(
  previous: PushSendSummary,
  outcomes: readonly ApnsSendResult[],
): PushSendSummary {
  if (outcomes.length === previous.devices) {
    return summarizeApnsSendResults(outcomes);
  }
  return {
    sent: previous.sent,
    devices: previous.devices,
    pruned: previous.pruned,
    transientFailures: 0,
    permanentFailures:
      previous.permanentFailures + previous.transientFailures,
  };
}

function targetIdentity(target: ApnsTarget): string {
  return [
    target.targetId ?? target.deviceToken,
    target.bundleId,
    target.environment,
  ].join("\0");
}

async function completeDelivery(
  dependencies: PushDeliveryDependencies,
  input: PushDeliveryInput,
  leaseToken: string | null,
  outcomes: readonly ApnsSendResult[],
  replayed: boolean,
  expirationEpochSeconds: number,
): Promise<DeliveryExecution> {
  if (!leaseToken) {
    return {
      ok: false,
      error: new PushDeliveryInProgressError({
        correlationId: input.correlationId,
        retryAfterSeconds: 1,
      }),
    };
  }
  const completedAt = new Date();
  const finalOutcomes = clampRetryToEventLife(
    outcomes,
    completedAt,
    expirationEpochSeconds,
  );
  const summary = summarizeApnsSendResults(finalOutcomes);
  const completed = await completePushSend(
    dependencies.db,
    input.userId,
    input.correlationId,
    leaseToken,
    summary,
    finalOutcomes,
    completedAt,
    new Date(expirationEpochSeconds * 1_000),
  );
  if (!completed) {
    return {
      ok: false,
      error: new PushDeliveryInProgressError({
        correlationId: input.correlationId,
        retryAfterSeconds: 1,
      }),
    };
  }
  dependencies.recordOutcome(summary, input.correlationId);
  return {
    ok: true,
    outcome: { summary, replayed },
  };
}
