import { z } from "zod";
import { DeviceRecordSchema, InboundPeerPermissionSchema, identifier, relayURL, revision, timestamp } from "./common";
import { ErrorResponseSchema } from "./responses";

/**
 * Per-user Mac directory served by AccountControl at `/v2/account/*`.
 *
 * These schemas are additive. Team requests and responses in `requests.ts`
 * and `responses.ts` are unchanged; an account socket or request never
 * accepts a team schema and a team socket never sends an account schema.
 */
export const ACCOUNT_MAC_LIMIT = 16;

export const AccountPublishRequestSchema = z.strictObject({
  schemaId: z.literal("account.publish.v1"),
  requestId: identifier,
});

export const AccountDirectoryRequestSchema = z.strictObject({
  schemaId: z.literal("account.directory.v1"),
  requestId: identifier,
});

export const AccountWithdrawRequestSchema = z.strictObject({
  schemaId: z.literal("account.withdraw.v1"),
  requestId: identifier,
});

/** Same-user Macs across every team, revalidated against each team's record on read. */
export const AccountDirectorySchema = z.strictObject({
  userId: identifier,
  revision,
  /** Macs that opted in to hosting (`cmux.mac-host.v1`) in the requester's app namespace, excluding the requester. */
  macs: z.array(DeviceRecordSchema).max(ACCOUNT_MAC_LIMIT),
  /** Only for a requester with `cmux.mac-host.v1`: Macs with `cmux.mac-devices.v1`, same namespace and build tag, current authority. */
  inboundMacs: z.array(InboundPeerPermissionSchema).max(ACCOUNT_MAC_LIMIT),
  relayURLs: z.array(relayURL).max(16),
  issuedAt: timestamp,
  permissionExpiresAt: timestamp,
  rules: z.array(identifier).max(32),
});

export const AccountReadyResponseSchema = z.strictObject({
  schemaId: z.literal("account.ready.v1"), requestId: identifier, sessionId: identifier, revision,
});
export const AccountPublishedResponseSchema = z.strictObject({
  schemaId: z.literal("account.published.v1"), requestId: identifier, revision, device: DeviceRecordSchema,
});
export const AccountDirectoryResponseSchema = z.strictObject({
  schemaId: z.literal("account.directory.result.v1"), requestId: identifier, directory: AccountDirectorySchema,
});
export const AccountWithdrawnResponseSchema = z.strictObject({
  schemaId: z.literal("account.withdrawn.v1"), requestId: identifier, revision,
});
/** Unsolicited: another of this user's Macs published, withdrew, or its team record changed. Re-read the directory. */
export const AccountChangedResponseSchema = z.strictObject({
  schemaId: z.literal("account.changed.v1"), userId: identifier, revision,
});

// Unions are not named `*Schema`, so contract generation emits each operation
// on its own instead of a flattened union model.
export const accountRequest = z.discriminatedUnion("schemaId", [
  AccountPublishRequestSchema, AccountDirectoryRequestSchema, AccountWithdrawRequestSchema,
]);
export const accountResponse = z.discriminatedUnion("schemaId", [
  ErrorResponseSchema, AccountReadyResponseSchema, AccountPublishedResponseSchema,
  AccountDirectoryResponseSchema, AccountWithdrawnResponseSchema, AccountChangedResponseSchema,
]);

export type AccountRequest = z.infer<typeof accountRequest>;
export type AccountResponse = z.infer<typeof accountResponse>;
export type AccountDirectory = z.infer<typeof AccountDirectorySchema>;

/** Rate-limit and telemetry names; arbitrary schema strings never become keys. */
export const accountOperationForSchema: Readonly<Record<AccountRequest["schemaId"], string>> = {
  "account.publish.v1": "account.publish",
  "account.directory.v1": "account.directory",
  "account.withdraw.v1": "account.withdraw",
};

export function accountOperation(input: unknown): string {
  if (input === null || typeof input !== "object") return "input.rejected";
  const schemaId = Reflect.get(input, "schemaId");
  return typeof schemaId === "string" && Object.hasOwn(accountOperationForSchema, schemaId)
    ? accountOperationForSchema[schemaId as AccountRequest["schemaId"]] : "input.rejected";
}
