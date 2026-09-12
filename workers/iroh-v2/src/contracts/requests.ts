import { z } from "zod";
import {
  DeliveryReceiptSchema, DeviceDescriptorSchema, DeviceMetadataSchema, DeviceProofSchema, PermissionSchema,
  identifier, relayURL, revision, signature,
} from "./common";
import { WorkspaceGetRequestSchema, WorkspaceListRequestSchema, WorkspaceSnapshotRequestSchema } from "./workspaces";
export { WorkspaceGetRequestSchema, WorkspaceListRequestSchema, WorkspaceSnapshotRequestSchema } from "./workspaces";

export const SocketSetupSchema = z.strictObject({
  schemaId: z.literal("session.open.v1"),
  requestId: identifier,
  device: DeviceDescriptorSchema,
  proof: DeviceProofSchema.optional(),
  haveRevision: revision.optional(),
});

export const ChallengeRequestSchema = z.strictObject({
  schemaId: z.literal("challenge.request.v1"),
  requestId: identifier,
  device: DeviceDescriptorSchema,
});

export const RegisterRequestSchema = z.strictObject({
  schemaId: z.literal("device.register.v1"),
  requestId: identifier,
  device: DeviceDescriptorSchema,
  challengeId: identifier,
  nonce: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  signature,
});

export const TicketRequestSchema = z.strictObject({
  schemaId: z.literal("ticket.request.v1"),
  requestId: identifier,
  stackAccessToken: z.string().min(1).max(8192),
});

export const RelayRequestSchema = z.strictObject({
  schemaId: z.literal("relay.request.v1"),
  requestId: identifier,
});

export const DirectoryRequestSchema = z.strictObject({
  schemaId: z.literal("directory.request.v1"),
  requestId: identifier,
  haveRevision: revision.optional(),
  cursor: identifier.optional(),
});

export const MetadataRequestSchema = z.strictObject({
  schemaId: z.literal("device.metadata.v1"),
  requestId: identifier,
  metadata: DeviceMetadataSchema,
});

export const RevokeRequestSchema = z.strictObject({
  schemaId: z.literal("device.revoke.v1"),
  requestId: identifier,
  deviceRecordId: identifier,
});

export const PermissionRequestSchema = z.strictObject({
  schemaId: z.literal("permission.update.v1"),
  requestId: identifier,
  permission: PermissionSchema,
});

export const PreferencesRequestSchema = z.strictObject({
  schemaId: z.literal("preferences.update.v1"),
  requestId: identifier,
  relayURLs: z.array(relayURL).min(1).max(16),
  expectedRevision: revision,
});

export const GoodbyeRequestSchema = z.strictObject({
  schemaId: z.literal("session.goodbye.v1"),
  requestId: identifier,
});

export const AcknowledgementRequestSchema = DeliveryReceiptSchema.extend({
  schemaId: z.literal("session.ack.v1"),
  requestId: identifier,
});

export const RequestSchema = z.discriminatedUnion("schemaId", [
  ChallengeRequestSchema, RegisterRequestSchema, TicketRequestSchema, RelayRequestSchema,
  DirectoryRequestSchema, MetadataRequestSchema, RevokeRequestSchema,
  PermissionRequestSchema, PreferencesRequestSchema, GoodbyeRequestSchema, AcknowledgementRequestSchema,
  WorkspaceSnapshotRequestSchema, WorkspaceGetRequestSchema, WorkspaceListRequestSchema,
]);

export type SocketSetup = z.infer<typeof SocketSetupSchema>;
export type RegisterRequest = z.infer<typeof RegisterRequestSchema>;
export type ControlRequest = z.infer<typeof RequestSchema>;
export type SchemaId = ControlRequest["schemaId"];

/** Wire revisions of the same operation share one user quota. */
export const operationForSchema: Record<SchemaId, string> = {
  "challenge.request.v1": "challenge.request",
  "device.register.v1": "device.register",
  "ticket.request.v1": "ticket.request",
  "relay.request.v1": "relay.request",
  "directory.request.v1": "directory.request",
  "device.metadata.v1": "device.metadata",
  "device.revoke.v1": "device.revoke",
  "permission.update.v1": "permission.update",
  "preferences.update.v1": "preferences.update",
  "session.goodbye.v1": "session.goodbye",
  "session.ack.v1": "session.ack",
  "workspace.snapshot.v1": "workspace.snapshot",
  "workspace.get.v1": "workspace.get",
  "workspace.list.v1": "workspace.list",
};
