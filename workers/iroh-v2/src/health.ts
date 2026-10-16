import { z } from "zod";
import { identifier } from "./contracts/common";

/**
 * Unauthenticated `GET /v2/health`: what is deployed, for operators and
 * `scripts/check-production-drift.ts`. A standalone operator document, not a
 * socket response, so it is deliberately outside the generated wire contracts
 * that every Mac and iOS client compiles.
 */
export const StorageCompatibilitySchema = z.strictObject({
  maxSchemaVersion: z.number().int().min(6).max(7),
  writeSchemaVersion: z.number().int().min(6).max(7),
}).refine(value => value.writeSchemaVersion <= value.maxSchemaVersion);

export const HealthSchema = z.strictObject({
  schemaId: z.literal("health.v1"), environment: identifier,
  sourceRevision: z.string().regex(/^(?:[0-9a-f]{7,64}|unknown)$/), rules: z.array(identifier).max(32),
  storage: StorageCompatibilitySchema.optional(),
});
export type Health = z.infer<typeof HealthSchema>;
