import { and, eq, or } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import type { cloudDb } from "../../db/client";
import { deviceTokens } from "../../db/schema";
import {
  completePushSend,
  recordPushSendOrThrow,
  releasePushSendLease,
  PushCorrelationConflictError,
  PushRateLimitExceededError,
} from "./rateLimit";
import {
  mergePushDeliveryOutcomes,
  unresolvedPushTargets,
} from "./deliveryState";
import type { PushPayload } from "./routePolicy";
import {
  type ApnsConfig,
  type ApnsSendResult,
  type ApnsTarget,
  sendApnsNotificationReliably,
} from "./sender";
import {
  summarizeApnsSendResults,
  type PushSendSummary,
} from "./response";
import {
  claimDeviceDeliveryTargets,
  DeviceDeliveryBusyError,
  releaseDeviceDeliveryTargets,
} from "./deviceDeliveryLease";

type PushDatabase = ReturnType<typeof cloudDb>;

export type PushDeliveryPayload = PushPayload & {
  readonly correlationId: string;
  readonly expirationEpochSeconds: number;
};

export interface PushDeliveryInput {
  readonly userId: string;
  readonly correlationId: string;
  readonly payloadFingerprint: string;
  readonly nowEpochSeconds: number;
  readonly expirationEpochSeconds: number;
  readonly payload: PushDeliveryPayload;
  readonly signal?: AbortSignal;
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

export type PushDeliveryError =
  | PushDeliveryInProgressError
  | PushDeliveryCorrelationConflictError
  | PushDeliveryRateLimitedError
  | PushDeliveryConfigurationError;

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
  let deviceClaim;
  try {
    deviceClaim = await claimDeviceDeliveryTargets(
      db,
      input.userId,
      new Date(),
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
    throw error;
  }

  try {
    return await executePushDeliveryWithTargets(
      input,
      dependencies,
      [...deviceClaim.targets],
    );
  } finally {
    await releaseDeviceDeliveryTargets(db, deviceClaim.leaseToken);
  }
}

async function executePushDeliveryWithTargets(
  input: PushDeliveryInput,
  dependencies: PushDeliveryDependencies,
  tokens: ApnsTarget[],
): Promise<DeliveryExecution> {
  const { db } = dependencies;

  let priorOutcomes: ApnsSendResult[] = [];
  let sendTargets: ApnsTarget[] = tokens;
  let deliveryPayload = input.payload;
  let leaseToken: string | null = null;
  try {
    const claim = await recordPushSendOrThrow(
      db,
      input.userId,
      tokens.length,
      input.correlationId,
      new Date(input.nowEpochSeconds * 1_000),
      new Date(input.expirationEpochSeconds * 1_000),
      input.payload.kind,
      tokens,
      input.payloadFingerprint,
    );
    if (claim.kind === "busy") {
      return {
        ok: false,
        error: new PushDeliveryInProgressError({
          correlationId: input.correlationId,
          retryAfterSeconds: claim.retryAfterSeconds,
        }),
      };
    }
    leaseToken = claim.leaseToken;
    const existing = claim.previous;
    if (existing) {
      if (existing.expiresAt) {
        deliveryPayload = {
          ...deliveryPayload,
          expirationEpochSeconds: Math.floor(
            existing.expiresAt.getTime() / 1_000,
          ),
        };
      }
    }
    if (existing?.summary) {
      const isExpired =
        existing.expiresAt != null
        && existing.expiresAt.getTime()
          <= input.nowEpochSeconds * 1_000;
      if (existing.summary.transientFailures === 0 || isExpired) {
        const completed = await completePushSend(
          db,
          input.userId,
          input.correlationId,
          claim.leaseToken,
          existing.summary,
          existing.outcomes,
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
        dependencies.recordOutcome(existing.summary, input.correlationId);
        return {
          ok: true,
          outcome: {
            summary: existing.summary,
            replayed: true,
          },
        };
      }
    }
    if (existing) {
      priorOutcomes = [...existing.outcomes];
      const currentByIdentity = new Map(
        tokens.map((target) => [targetIdentity(target), target]),
      );
      const originalTargets =
        existing.initialTargets ?? tokens;
      const unresolvedOriginalTargets = unresolvedPushTargets(
        originalTargets,
        priorOutcomes,
      );
      const removedOutcomes = unresolvedOriginalTargets
        .filter(
          (target) => !currentByIdentity.has(targetIdentity(target)),
        )
        .map((target): ApnsSendResult => ({
          targetId: target.targetId,
          deviceToken: target.deviceToken,
          status: 404,
          reason: "target_no_longer_registered",
          prune: false,
        }));
      priorOutcomes = mergePushDeliveryOutcomes(
        priorOutcomes,
        removedOutcomes,
      );
      const stillRegisteredOriginalTargets = originalTargets.flatMap(
        (target) => {
          const current = currentByIdentity.get(targetIdentity(target));
          return current ? [current] : [];
        },
      );
      sendTargets = unresolvedPushTargets(
        stillRegisteredOriginalTargets,
        priorOutcomes,
      );
      if (sendTargets.length === 0) {
        return await completeDelivery(
          dependencies,
          input,
          claim.leaseToken,
          priorOutcomes,
          true,
        );
      }
    }
  } catch (error) {
    if (error instanceof PushCorrelationConflictError) {
      return {
        ok: false,
        error: new PushDeliveryCorrelationConflictError({
          correlationId: input.correlationId,
        }),
      };
    }
    if (error instanceof PushRateLimitExceededError) {
      return {
        ok: false,
        error: new PushDeliveryRateLimitedError({
          retryAfterSeconds: error.retryAfterSeconds,
        }),
      };
    }
    throw error;
  }

  if (sendTargets.length === 0) {
    return await completeDelivery(
      dependencies,
      input,
      leaseToken,
      priorOutcomes,
      false,
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

  const rawResults = await (
    dependencies.send ?? sendApnsNotificationReliably
  )(
    dependencies.config,
    sendTargets,
    deliveryPayload,
    { signal: input.signal },
  );
  const sentTargetByToken = new Map(
    sendTargets.map((target) => [target.deviceToken, target]),
  );
  const results = rawResults.map((result) => ({
    ...result,
    targetId:
      result.targetId
      ?? sentTargetByToken.get(result.deviceToken)?.targetId,
  }));
  const deadTargets = results.flatMap((result) => {
    if (!result.prune) return [];
    const target = sentTargetByToken.get(result.deviceToken);
    return target?.targetId ? [target] : [];
  });
  const exactDeadTargetPredicate = or(
    ...deadTargets.map((target) => and(
      eq(deviceTokens.id, target.targetId!),
      eq(deviceTokens.deviceToken, target.deviceToken),
      eq(deviceTokens.bundleId, target.bundleId),
      eq(deviceTokens.environment, target.environment),
    )),
  );
  if (exactDeadTargetPredicate) {
    await db
      .delete(deviceTokens)
      .where(
        and(
          eq(deviceTokens.userId, input.userId),
          eq(deviceTokens.platform, "ios"),
          exactDeadTargetPredicate,
        ),
      );
  }

  return await completeDelivery(
    dependencies,
    input,
    leaseToken,
    mergePushDeliveryOutcomes(priorOutcomes, results),
    false,
  );
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
  const summary = summarizeApnsSendResults(outcomes);
  const completed = await completePushSend(
    dependencies.db,
    input.userId,
    input.correlationId,
    leaseToken,
    summary,
    outcomes,
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
