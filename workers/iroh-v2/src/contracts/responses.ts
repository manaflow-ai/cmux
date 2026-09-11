import { z } from "zod";
import { ChallengeSchema, DeviceRecordSchema, DirectorySchema, RelayCredentialSchema, TicketSchema, identifier, revision } from "./common";

export const ErrorCodeSchema = z.enum([
  "invalid_request", "unsupported_method", "payload_too_large", "unsupported_media_type",
  "unauthorized", "ticket_expired", "invalid_device_proof", "proof_replayed",
  "team_access_revoked", "permission_denied", "device_revoked", "identity_mismatch",
  "environment_mismatch", "device_not_enrolled", "endpoint_already_owned",
  "challenge_missing", "challenge_replaced", "challenge_expired", "challenge_invalid",
  "key_replacement_required", "revision_conflict", "rate_limited", "client_upgrade_required",
  "device_limit", "storage_limit", "storage_unavailable", "upstream_unavailable",
  "slow_consumer", "resync_required", "internal_error",
]);

export const ErrorResponseSchema = z.strictObject({
  schemaId: z.literal("error.v1"),
  requestId: identifier,
  code: ErrorCodeSchema,
  retryable: z.boolean(),
  retryAfterMs: z.number().int().nonnegative().safe().optional(),
});

export const ReadyResponseSchema = z.strictObject({
  schemaId: z.literal("session.ready.v1"),
  requestId: identifier,
  sessionId: identifier,
  teamRevision: revision,
  ticket: TicketSchema.optional(),
  challenge: ChallengeSchema.optional(),
  device: DeviceRecordSchema.optional(),
});

export const RegisteredResponseSchema = z.strictObject({
  schemaId: z.literal("device.registered.v1"),
  requestId: identifier,
  device: DeviceRecordSchema,
});

export const ChallengeResponseSchema = z.strictObject({
  schemaId: z.literal("challenge.result.v1"), requestId: identifier, challenge: ChallengeSchema,
});
export const TicketResponseSchema = z.strictObject({
  schemaId: z.literal("ticket.result.v1"), requestId: identifier, ticket: TicketSchema,
});
export const RelayResponseSchema = z.strictObject({
  schemaId: z.literal("relay.result.v1"), requestId: identifier,
  credentials: z.array(RelayCredentialSchema).min(1).max(16),
});
export const DirectoryResponseSchema = z.strictObject({
  schemaId: z.literal("directory.result.v1"), requestId: identifier, directory: DirectorySchema,
});
export const ChangedResponseSchema = z.strictObject({
  schemaId: z.literal("directory.changed.v1"), teamId: identifier, revision,
});
export const RevokedResponseSchema = z.strictObject({
  schemaId: z.literal("device.revoked.v1"), teamId: identifier, deviceRecordId: identifier, revision,
});
export const CompletedResponseSchema = z.strictObject({
  schemaId: z.literal("operation.completed.v1"), requestId: identifier, revision,
});

export const ResponseSchema = z.discriminatedUnion("schemaId", [
  ErrorResponseSchema, ReadyResponseSchema, RegisteredResponseSchema,
  ChallengeResponseSchema, TicketResponseSchema, RelayResponseSchema, DirectoryResponseSchema,
  ChangedResponseSchema, RevokedResponseSchema, CompletedResponseSchema,
]);
export type ControlResponse = z.infer<typeof ResponseSchema>;
export type ErrorCode = z.infer<typeof ErrorCodeSchema>;
