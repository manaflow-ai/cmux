import { and, eq, inArray } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import type { cloudDb } from "../../db/client";
import { deviceTokens } from "../../db/schema";
import {
  completePushSend,
  recordPushSendOrThrow,
  PushCorrelationConflictError,
  PushRateLimitExceededError,
} from "./rateLimit";
import {
  mergePushDeliveryOutcomes,
  unresolvedPushTargets,
} from "./deliveryState";
import { MAX_DEVICE_TOKENS_PER_USER, type PushPayload } from "./routePolicy";
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
}

export interface PushDeliveryOutcome {
  readonly summary: PushSendSummary;
  readonly replayed: boolean;
}

export class PushDeliveryInProgressError extends Data.TaggedError(
  "PushDeliveryInProgressError",
)<{
  readonly correlationId: string;
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
  const tokens = await db
    .select({
      deviceToken: deviceTokens.deviceToken,
      bundleId: deviceTokens.bundleId,
      environment: deviceTokens.environment,
    })
    .from(deviceTokens)
    .where(
      and(
        eq(deviceTokens.userId, input.userId),
        eq(deviceTokens.platform, "ios"),
      ),
    )
    .limit(MAX_DEVICE_TOKENS_PER_USER);

  let priorOutcomes: ApnsSendResult[] = [];
  let sendTargets: ApnsTarget[] = tokens;
  let deliveryPayload = input.payload;
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
        }),
      };
    }
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
        await completePushSend(
          db,
          input.userId,
          input.correlationId,
          existing.summary,
          existing.outcomes,
        );
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
      priorOutcomes,
      false,
    );
  }
  if (!dependencies.config) {
    return {
      ok: false,
      error: new PushDeliveryConfigurationError({
        code: "push_service_not_configured",
      }),
    };
  }

  const results = await (
    dependencies.send ?? sendApnsNotificationReliably
  )(
    dependencies.config,
    sendTargets,
    deliveryPayload,
  );
  const dead = results
    .filter((result) => result.prune)
    .map((result) => result.deviceToken);
  if (dead.length > 0) {
    await db
      .delete(deviceTokens)
      .where(
        and(
          eq(deviceTokens.userId, input.userId),
          eq(deviceTokens.platform, "ios"),
          inArray(deviceTokens.deviceToken, dead),
        ),
      );
  }

  return await completeDelivery(
    dependencies,
    input,
    mergePushDeliveryOutcomes(priorOutcomes, results),
    false,
  );
}

function targetIdentity(target: ApnsTarget): string {
  return [
    target.deviceToken,
    target.bundleId,
    target.environment,
  ].join("\0");
}

async function completeDelivery(
  dependencies: PushDeliveryDependencies,
  input: PushDeliveryInput,
  outcomes: readonly ApnsSendResult[],
  replayed: boolean,
): Promise<DeliveryExecution> {
  const summary = summarizeApnsSendResults(outcomes);
  await completePushSend(
    dependencies.db,
    input.userId,
    input.correlationId,
    summary,
    outcomes,
  );
  dependencies.recordOutcome(summary, input.correlationId);
  return {
    ok: true,
    outcome: { summary, replayed },
  };
}
