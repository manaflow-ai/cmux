import { z } from "zod";

export const identifier = z.string().min(1).max(128);
export const timestamp = z.number().int().nonnegative().safe();
export const revision = z.number().int().nonnegative().safe();
export const endpointID = z.string().regex(/^[0-9a-f]{64}$/);
export const signature = z.string().regex(/^[A-Za-z0-9_-]{86}$/);
export const relayURL = z.url().max(2048).refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password && !url.search && !url.hash;
}, "Relay URLs must use HTTPS without credentials, a query, or a fragment");

/** Every identity/cache/key entry includes the complete authorization scope. */
export const IdentitySchema = z.strictObject({
  environment: identifier,
  projectId: identifier,
  teamId: identifier,
  userId: identifier,
  deviceId: identifier,
  appNamespace: z.string().min(1).max(255),
  buildTag: z.string().min(1).max(64),
});

export const DeviceMetadataSchema = z.strictObject({
  platform: z.enum(["mac", "ios"]),
  displayName: z.string().min(1).max(128),
  appVersion: z.string().min(1).max(64),
  pairingEnabled: z.boolean(),
  capabilities: z.array(z.string().min(1).max(64)).max(32),
  relayURLs: z.array(relayURL).max(16),
});

export const DeviceDescriptorSchema = z.strictObject({
  identity: IdentitySchema,
  endpointId: endpointID,
  identityGeneration: revision,
  metadata: DeviceMetadataSchema,
});

export const DeviceRecordSchema = z.strictObject({
  deviceRecordId: identifier,
  descriptor: DeviceDescriptorSchema,
  revision,
  revoked: z.boolean(),
});

export const ChallengeSchema = z.strictObject({
  challengeId: identifier,
  nonce: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  payloadHash: endpointID,
  expiresAt: timestamp,
});

/** Proof covers the exact operation and body, never an EndpointID alone. */
export const DeviceProofSchema = z.strictObject({
  requestId: identifier,
  nonce: z.string().regex(/^[A-Za-z0-9_-]{22}$/),
  issuedAt: timestamp,
  signature,
});

export const RelayCredentialSchema = z.strictObject({
  relayURL,
  token: z.string().min(1).max(8192),
  expiresAt: timestamp,
  refreshAfter: timestamp,
});

export const TicketSchema = z.strictObject({
  token: z.string().min(1).max(8192),
  expiresAt: timestamp,
  refreshAfter: timestamp,
});

/** Returned only after a batch of real output, never on an idle timer. */
export const DeliveryReceiptSchema = z.strictObject({
  sequence: revision,
  token: z.string().regex(/^[A-Za-z0-9_-]{22}$/),
});

export const PermissionSchema = z.strictObject({
  subjectUserId: identifier,
  deviceRecordId: identifier,
  connect: z.boolean(),
  manage: z.boolean(),
});

/** A peer allowed to connect to the requesting Mac, with bounded authority. */
export const InboundPeerPermissionSchema = z.strictObject({
  device: DeviceRecordSchema,
  permissionExpiresAt: timestamp,
});

export const DirectorySchema = z.strictObject({
  teamId: identifier,
  revision,
  devices: z.array(DeviceRecordSchema).max(1024),
  inboundPeers: z.array(InboundPeerPermissionSchema).max(1024).optional(),
  relayURLs: z.array(relayURL).max(16),
  issuedAt: timestamp,
  permissionExpiresAt: timestamp,
  nextCursor: identifier.nullable(),
});

export type Identity = z.infer<typeof IdentitySchema>;
export type DeviceDescriptor = z.infer<typeof DeviceDescriptorSchema>;
export type DeviceMetadata = z.infer<typeof DeviceMetadataSchema>;
export type DeviceRecord = z.infer<typeof DeviceRecordSchema>;
export type Challenge = z.infer<typeof ChallengeSchema>;
export type DeviceProof = z.infer<typeof DeviceProofSchema>;
export type Directory = z.infer<typeof DirectorySchema>;
export type Permission = z.infer<typeof PermissionSchema>;
