import { randomUUID } from "node:crypto";
import { and, eq, sql } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { runAttempts, runs } from "../../db/schema";
import type {
  AttemptPromotionStorePort,
  PromotionReserveResult,
  PromotionReservation,
  PromotionView,
} from "./promotion";

/** Internal marker kept in the attempt result JSON until a promotion table is available. */
const MARKER = "_cmuxPromotion";

type PromotionMarker = {
  readonly status: "pending" | "completed";
  readonly claimId: string;
  readonly requestKey: string;
  readonly runId: string;
  readonly attemptId: string;
  readonly promotion?: PromotionView;
};

function markerFrom(value: unknown): PromotionMarker | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const candidate = (value as Record<string, unknown>)[MARKER];
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) return null;
  const marker = candidate as Partial<PromotionMarker>;
  if ((marker.status !== "pending" && marker.status !== "completed")
    || typeof marker.claimId !== "string"
    || typeof marker.requestKey !== "string"
    || typeof marker.runId !== "string"
    || typeof marker.attemptId !== "string") return null;
  if (marker.status === "completed" && (!marker.promotion || typeof marker.promotion !== "object")) return null;
  return marker as PromotionMarker;
}

function withMarker(result: Record<string, unknown> | null, marker: PromotionMarker): Record<string, unknown> {
  return { ...(result ?? {}), [MARKER]: marker };
}

function sameTarget(marker: PromotionMarker, input: { runId: string; attemptId: string }): boolean {
  return marker.runId === input.runId && marker.attemptId === input.attemptId;
}

function storedPromotion(marker: PromotionMarker): PromotionView | null {
  return marker.status === "completed" && marker.promotion ? marker.promotion : null;
}

/**
 * Durable promotion idempotency using the existing terminal attempt row.
 * `reserve` locks the tenant-owned run and attempt, while `complete` keeps a
 * redacted PromotionView in the result JSON. A future promotion table can
 * replace this adapter without changing the service port.
 */
export function createRunAttemptPromotionStore(): AttemptPromotionStorePort {
  return {
    async findByRequestKey(input): Promise<PromotionView | null> {
      const rows = await cloudDb().select({ result: runAttempts.result }).from(runAttempts).innerJoin(
        runs,
        eq(runs.id, runAttempts.runId),
      ).where(and(
        eq(runs.userId, input.userId),
        sql`${runAttempts.result}->${MARKER}->>'requestKey' = ${input.requestKey}`,
      )).limit(1);
      const marker = markerFrom(rows[0]?.result);
      return marker ? storedPromotion(marker) : null;
    },

    async reserve(input): Promise<PromotionReserveResult> {
      return cloudDb().transaction(async (tx) => {
        const run = (await tx.select({ id: runs.id }).from(runs).where(and(
          eq(runs.id, input.runId),
          eq(runs.userId, input.userId),
        )).for("update").limit(1))[0];
        if (!run) return { kind: "in_progress" };
        const attempt = (await tx.select().from(runAttempts).where(and(
          eq(runAttempts.id, input.attemptId),
          eq(runAttempts.runId, input.runId),
        )).for("update").limit(1))[0];
        if (!attempt) return { kind: "in_progress" };
        const marker = markerFrom(attempt.result);
        if (marker) {
          if (marker.requestKey === input.requestKey && sameTarget(marker, input)) {
            const promotion = storedPromotion(marker);
            if (promotion) return { kind: "replay", promotion };
            return { kind: "in_progress" };
          }
          if (marker.requestKey === input.requestKey) return { kind: "idempotency_conflict" };
          const promotion = storedPromotion(marker);
          if (promotion && sameTarget(marker, input)) return { kind: "duplicate", promotion };
          return { kind: "idempotency_conflict" };
        }

        const reservation: PromotionReservation = { claimId: randomUUID() };
        const pending: PromotionMarker = {
          status: "pending",
          claimId: reservation.claimId,
          requestKey: input.requestKey,
          runId: input.runId,
          attemptId: input.attemptId,
        };
        await tx.update(runAttempts).set({
          result: withMarker(attempt.result, pending),
          updatedAt: new Date(),
        }).where(and(eq(runAttempts.id, input.attemptId), eq(runAttempts.runId, input.runId)));
        return { kind: "reserved", reservation };
      });
    },

    async complete(input): Promise<PromotionView> {
      return cloudDb().transaction(async (tx) => {
        const rows = await tx.select().from(runAttempts).where(sql`${runAttempts.result}->${MARKER}->>'claimId' = ${input.reservation.claimId}`).for("update");
        const attempt = rows[0];
        const marker = markerFrom(attempt?.result);
        if (!attempt || !marker || marker.status !== "pending" || marker.claimId !== input.reservation.claimId) {
          throw new Error("promotion reservation is no longer active");
        }
        const completed: PromotionMarker = { ...marker, status: "completed", promotion: input.promotion };
        await tx.update(runAttempts).set({ result: withMarker(attempt.result, completed), updatedAt: new Date() }).where(eq(runAttempts.id, attempt.id));
        return input.promotion;
      });
    },

    async release(reservation): Promise<void> {
      await cloudDb().update(runAttempts).set({
        result: sql`case when ${runAttempts.result} is null then null else ${runAttempts.result} - ${MARKER} end`,
        updatedAt: new Date(),
      }).where(sql`${runAttempts.result}->${MARKER}->>'claimId' = ${reservation.claimId}`);
    },
  };
}

