/**
 * Identifier kinds. Effect brands say what kind of value an id is; gdp-ts names
 * (see src/proofs/) say which value it is.
 *
 * Public ids are opaque: a kind prefix plus 26 lowercase base32 characters
 * (128 random bits). They carry no upstream information. Upstream ids are a
 * separate brand that no public schema accepts or returns.
 */
import { Schema } from "effect";

const BASE32 = "0123456789abcdefghjkmnpqrstvwxyz";
const BODY_LENGTH = 26;

/** The resource kinds the ownership table records, with their public id prefixes. */
export const RESOURCE_PREFIXES = {
  vm: "vm_",
  snapshot: "snap_",
  mesh: "mesh_",
  device: "dev_",
  tunnel: "tun_",
} as const;

export const ResourceKind = Schema.Literal("vm", "snapshot", "mesh", "device", "tunnel");
export type ResourceKind = typeof ResourceKind.Type;

const opaque = (prefix: string) => new RegExp(`^${prefix}[${BASE32}]{${BODY_LENGTH}}$`);

export const VmId = Schema.String.pipe(Schema.pattern(opaque(RESOURCE_PREFIXES.vm)), Schema.brand("VmId"));
export type VmId = typeof VmId.Type;

export const SnapshotId = Schema.String.pipe(Schema.pattern(opaque(RESOURCE_PREFIXES.snapshot)), Schema.brand("SnapshotId"));
export type SnapshotId = typeof SnapshotId.Type;

/** A mesh (experiment, cx-0op): one private network per tenant. */
export const MeshId = Schema.String.pipe(Schema.pattern(opaque(RESOURCE_PREFIXES.mesh)), Schema.brand("MeshId"));
export type MeshId = typeof MeshId.Type;

/** A device enrolled in a mesh with its own WireGuard key. */
export const DeviceId = Schema.String.pipe(Schema.pattern(opaque(RESOURCE_PREFIXES.device)), Schema.brand("DeviceId"));
export type DeviceId = typeof DeviceId.Type;

/** A device's tunnel into its mesh; exactly one per device. */
export const TunnelId = Schema.String.pipe(Schema.pattern(opaque(RESOURCE_PREFIXES.tunnel)), Schema.brand("TunnelId"));
export type TunnelId = typeof TunnelId.Type;

/** Any public resource id. */
export type ResourceId = VmId | SnapshotId | MeshId | DeviceId | TunnelId;

/** API key ids are public (shown in key listings and audit logs); the secret is not. */
export const ApiKeyId = Schema.String.pipe(Schema.pattern(opaque("vmk_")), Schema.brand("ApiKeyId"));
export type ApiKeyId = typeof ApiKeyId.Type;

/** A tenant is a Stack Auth team id. */
export const TenantId = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(128),
  Schema.pattern(/^[A-Za-z0-9_-]+$/),
  Schema.brand("TenantId"),
);
export type TenantId = typeof TenantId.Type;

/** A Stack Auth user id. */
export const UserId = Schema.String.pipe(
  Schema.minLength(1),
  Schema.maxLength(128),
  Schema.pattern(/^[A-Za-z0-9_-]+$/),
  Schema.brand("UserId"),
);
export type UserId = typeof UserId.Type;

/** The provider's id for a resource. Internal only: never in a response, error or log. */
export const UpstreamId = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(256), Schema.brand("UpstreamId"));
export type UpstreamId = typeof UpstreamId.Type;

/** 26 base32 characters carrying 128 random bits (the last character's low two bits are always zero). */
export function randomIdBody(random: (bytes: Uint8Array) => Uint8Array = (bytes) => crypto.getRandomValues(bytes)): string {
  const bytes = random(new Uint8Array(17));
  bytes[16] = 0;
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5 && out.length < BODY_LENGTH) {
      out += BASE32.charAt((value >>> (bits - 5)) & 31);
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  return out;
}

export const newVmId = (): VmId => VmId.make(RESOURCE_PREFIXES.vm + randomIdBody());
export const newSnapshotId = (): SnapshotId => SnapshotId.make(RESOURCE_PREFIXES.snapshot + randomIdBody());
export const newMeshId = (): MeshId => MeshId.make(RESOURCE_PREFIXES.mesh + randomIdBody());
export const newDeviceId = (): DeviceId => DeviceId.make(RESOURCE_PREFIXES.device + randomIdBody());
export const newTunnelId = (): TunnelId => TunnelId.make(RESOURCE_PREFIXES.tunnel + randomIdBody());
export const newApiKeyId = (): ApiKeyId => ApiKeyId.make("vmk_" + randomIdBody());

/** Decodes a public VM id; any malformed input is simply "no such VM". */
export const parseVmId = Schema.decodeUnknownOption(VmId);

/** Decodes a public snapshot id; any malformed input is simply "no such snapshot". */
export const parseSnapshotId = Schema.decodeUnknownOption(SnapshotId);

/** Decodes public mesh, device and tunnel ids; malformed input is "not found". */
export const parseMeshId = Schema.decodeUnknownOption(MeshId);
export const parseDeviceId = Schema.decodeUnknownOption(DeviceId);
export const parseTunnelId = Schema.decodeUnknownOption(TunnelId);
