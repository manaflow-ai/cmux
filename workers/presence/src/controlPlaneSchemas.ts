import { z } from "zod";

const revision = z.number().int().nonnegative().safe();
const boundedString = (max: number) => z.string().min(1).max(max);
const isoDate = z.string().datetime({ offset: true });
const stringArray = z.array(boundedString(256)).max(64);
const proof = z.strictObject({
  bindingId: boundedString(128),
  timestamp: boundedString(64),
  signature: boundedString(512),
});
const binding = z.strictObject({
  bindingId: boundedString(128),
  endpointId: boundedString(128),
  clientNamespace: boundedString(255),
  revoked: z.boolean(),
  deviceId: z.string().max(255).nullable().optional(),
  instanceTag: z.string().max(64).nullable().optional(),
  // URL shape is validated by the broker policy so malformed hints produce the
  // protocol's typed invalid_hint response instead of a generic frame drop.
  homeRelayUrl: z.string().max(2048).nullable().optional(),
  updatedAt: isoDate.nullable().optional(),
  status: z.enum(["active", "seeded", "stale", "retired", "suspended", "pending", "superseded"]).optional(),
  appVersion: z.string().max(128).optional(),
  releaseTrack: z.enum(["nightly", "stable", "internal", "beta", "appstore", "dev"]).optional(),
  capabilities: stringArray.optional(),
  lastConfirmedAt: isoDate.optional(),
});
const pass = z.strictObject({
  relayUrl: z.string().url(),
  token: boundedString(16 * 1024),
  expiresAt: isoDate,
  refreshAfter: isoDate,
  generation: revision,
});
const minimumSupportedVersion = z.strictObject({
  mac: z.string().max(128).optional(),
  ios: z.string().max(128).optional(),
});

const helloFrame = z.strictObject({
  v: z.literal(1),
  type: z.literal("hello"),
  payload: z.strictObject({
    endpointId: boundedString(128),
    wantPasses: z.boolean(),
    haveRev: revision.nullable().optional(),
    deviceId: z.string().max(255).optional(),
    platform: z.enum(["mac", "ios"]).optional(),
    appVersion: z.string().max(128).optional(),
    releaseTrack: z.enum(["nightly", "stable", "internal", "beta", "appstore", "dev"]).optional(),
    capabilities: stringArray.optional(),
  }),
});
const helloAckFrame = z.strictObject({
  v: z.literal(1),
  type: z.literal("hello_ack"),
  payload: z.strictObject({
    sessionId: boundedString(128),
    resumedFromRev: revision.nullable().optional(),
    serverCapabilities: stringArray.optional(),
    minimumSupportedVersion: minimumSupportedVersion.optional(),
  }),
});
const directoryFrame = z.strictObject({
  v: z.literal(1),
  type: z.literal("directory"),
  rev: revision,
  payload: z.strictObject({
    routeContractVersion: revision,
    bindings: z.array(binding).max(256),
    relayFleet: z.array(z.string().url()).max(32),
    grantVerificationKeys: z.array(z.strictObject({
      keyId: boundedString(128),
      alg: boundedString(32),
      publicKey: boundedString(4096),
    })).max(32),
    issuedAt: isoDate,
    ttlSeconds: z.number().int().positive().max(86_400),
    minimumSupportedVersion: minimumSupportedVersion.optional(),
  }),
});
const hintUpdateFrame = z.strictObject({
  v: z.literal(1), type: z.literal("hint_update"), rev: revision,
  payload: z.strictObject({ endpointId: boundedString(128), homeRelayUrl: z.string().max(2048), updatedAt: isoDate.nullable().optional() }),
});
const relayPassesFrame = z.strictObject({
  v: z.literal(1), type: z.literal("relay_passes"), rev: revision,
  payload: z.strictObject({ endpointId: boundedString(128), passes: z.array(pass).max(32) }),
});
const snapshotCompleteFrame = z.strictObject({
  v: z.literal(1), type: z.literal("snapshot_complete"), rev: revision,
  payload: z.strictObject({ issuedAt: isoDate.optional() }),
});
const ackFrame = z.strictObject({
  v: z.literal(1), type: z.literal("ack"), rev: revision,
  payload: z.strictObject({ appliedAt: isoDate.optional() }),
});
const errorFrame = z.strictObject({
  v: z.literal(1), type: z.literal("error"),
  payload: z.strictObject({ code: boundedString(128), message: boundedString(512), retryable: z.boolean() }),
});
const mintRequestFrame = z.strictObject({
  v: z.literal(1), type: z.literal("mint_request"),
  payload: z.strictObject({ endpointId: boundedString(128), proof: proof.optional() }),
});
const publishHintFrame = z.strictObject({
  v: z.literal(1), type: z.literal("publish_hint"),
  payload: z.strictObject({ endpointId: boundedString(128), homeRelayUrl: z.string().max(2048), proof: proof.optional() }),
});

export const ControlFrameSchema = z.discriminatedUnion("type", [
  helloFrame, helloAckFrame, directoryFrame, hintUpdateFrame, relayPassesFrame,
  snapshotCompleteFrame, ackFrame, errorFrame, mintRequestFrame, publishHintFrame,
]);
export type ControlFrame = z.infer<typeof ControlFrameSchema>;

export function decodeControlFrameSchema(value: unknown): ControlFrame | null {
  const result = ControlFrameSchema.safeParse(value);
  return result.success ? result.data : null;
}

export function encodeControlFrameSchema(value: ControlFrame): string {
  return JSON.stringify(ControlFrameSchema.parse(value));
}
