/**
 * Mesh experiment tables (migrations/0004_cmux_vm_mesh.sql). The mesh, device
 * and tunnel ownership rows live in cmux_vm.resources like every other kind;
 * these tables hold what only a mesh has: its address block, its devices, its
 * VM members, its ACL versions and the provider firewall rules the ACL made.
 * Every read and write is keyed by tenant and mesh, so another tenant's rows
 * are indistinguishable from rows that do not exist.
 */
import { Context, Effect, Layer, Option, Schema } from "effect";
import { TenantId as TenantIdBrand, type TenantId } from "../lib/ids.ts";
import type { AclDocument, MeshProtocol } from "../mesh/acl.ts";
import { SqlClient, StoreError } from "./sql.ts";

export interface MeshDeviceRow {
  readonly deviceId: string;
  readonly meshId: string;
  readonly tunnelId: string;
  readonly name: string;
  readonly wgPublicKey: string;
  /** The install key (M2) that signs the device's enroll and key rotation; null for a device enrolled before M2. */
  readonly installPublicKey: string | null;
  readonly createdBy: string;
  readonly createdAt: Date;
}

/** A one-time enrollment code (M2), by the SHA-256 of the code. */
export interface MeshEnrollmentCodeRow {
  readonly codeSha256: string;
  readonly tenantId: TenantId;
  readonly meshId: string;
  readonly createdBy: string;
  readonly createdAt: Date;
  readonly expiresAt: Date;
  readonly usedAt: Date | null;
}

export interface MeshMemberRow {
  readonly meshId: string;
  readonly vmId: string;
  /** The VM's IPv4 address inside the mesh; null when the provider gave none. */
  readonly ipv4: string | null;
  readonly attachedAt: Date;
}

export interface MeshAclVersion {
  readonly version: number;
  readonly document: AclDocument;
  readonly sha256: string;
  readonly author: string;
  readonly createdAt: Date;
}

/** A provider firewall rule this mesh's ACL created. The provider id never leaves src/proofs and src/upstream. */
export interface MeshRuleRow {
  readonly meshId: string;
  readonly key: string;
  readonly upstreamRuleId: string;
  readonly deviceId: string;
  readonly vmId: string;
  readonly protocol: MeshProtocol | null;
  readonly port: number | null;
  readonly createdAt: Date;
}

export interface MeshStoreService {
  /** Claims address slot `slot` for the mesh; false when another mesh holds it. */
  readonly claimSlot: (tenantId: TenantId, meshId: string, slot: number, cidr: string) => Effect.Effect<boolean, StoreError>;
  readonly releaseSlot: (tenantId: TenantId, meshId: string) => Effect.Effect<void, StoreError>;
  readonly cidrOf: (tenantId: TenantId, meshId: string) => Effect.Effect<Option.Option<string>, StoreError>;

  readonly recordDevice: (tenantId: TenantId, device: MeshDeviceRow) => Effect.Effect<void, StoreError>;
  readonly getDevice: (tenantId: TenantId, deviceId: string) => Effect.Effect<Option.Option<MeshDeviceRow>, StoreError>;
  readonly getDeviceByTunnel: (tenantId: TenantId, tunnelId: string) => Effect.Effect<Option.Option<MeshDeviceRow>, StoreError>;
  readonly listDevices: (tenantId: TenantId, meshId: string) => Effect.Effect<ReadonlyArray<MeshDeviceRow>, StoreError>;
  /**
   * Any tenant's live device with this id (M3). Only the credential-free
   * device routes use it: the device's install-key signature is the credential
   * there, so the tenant comes from the device, never from the request.
   */
  readonly findDeviceForSignedRequest: (deviceId: string) => Effect.Effect<Option.Option<MeshDeviceRow & { readonly tenantId: TenantId }>, StoreError>;
  readonly markDeviceDeleted: (tenantId: TenantId, deviceId: string, at: Date) => Effect.Effect<void, StoreError>;
  /** The tenant's live devices, in every mesh, whose `created_by` is exactly `createdBy` (G1: a removed member's devices). */
  readonly listDevicesCreatedBy: (tenantId: TenantId, createdBy: string) => Effect.Effect<ReadonlyArray<MeshDeviceRow>, StoreError>;
  /** Every tenant where a live device's `created_by` is exactly `createdBy` (Stack `user.deleted`); each once. */
  readonly listTenantsWithDevicesCreatedBy: (createdBy: string) => Effect.Effect<ReadonlyArray<TenantId>, StoreError>;
  /** Records a rotated WireGuard key; false when another live device of the mesh holds it. */
  readonly updateDeviceKey: (tenantId: TenantId, deviceId: string, wgPublicKey: string, at: Date) => Effect.Effect<boolean, StoreError>;
  /** Sets (or with null clears) a live device's published public IPv6 address (migration 0009); false when the device is not live in this tenant. */
  readonly setDeviceAddress: (tenantId: TenantId, deviceId: string, publicIpv6: string | null, at: Date) => Effect.Effect<boolean, StoreError>;
  /** The published public IPv6 address of every live device of the mesh that has one, by device id. */
  readonly deviceAddresses: (tenantId: TenantId, meshId: string) => Effect.Effect<ReadonlyMap<string, string>, StoreError>;

  /** Stores an accepted signed message (and prunes expired ones); false when it was stored before (a replay). */
  readonly claimSignedRequest: (tenantId: TenantId, messageSha256: string, purpose: string, expiresAt: Date, now: Date) => Effect.Effect<boolean, StoreError>;

  readonly insertEnrollmentCode: (code: Omit<MeshEnrollmentCodeRow, "usedAt">) => Effect.Effect<void, StoreError>;
  /** Codes created for this mesh since `since` (the hourly budget). */
  readonly enrollmentCodesSince: (tenantId: TenantId, meshId: string, since: Date) => Effect.Effect<ReadonlyArray<Date>, StoreError>;
  /** Any tenant's unused, unexpired code with this hash for this mesh: the code is the credential. */
  readonly findEnrollmentCode: (codeSha256: string, meshId: string, now: Date) => Effect.Effect<Option.Option<MeshEnrollmentCodeRow>, StoreError>;
  /** Marks the code used, atomically; false when it was used or expired meanwhile. */
  readonly consumeEnrollmentCode: (codeSha256: string, meshId: string, now: Date) => Effect.Effect<boolean, StoreError>;
  readonly recordEnrollmentCodeDevice: (codeSha256: string, deviceId: string) => Effect.Effect<void, StoreError>;
  /**
   * Burns the code with this hash, in any mesh (M3): marks it used and ends its
   * validity now, so a later restore cannot revive it. A code that made a
   * device is left as it is; an unknown hash is a no-op.
   */
  readonly burnEnrollmentCode: (codeSha256: string, now: Date) => Effect.Effect<void, StoreError>;
  /**
   * Gives back the claim `consumeEnrollmentCode` made at `usedAt` (M3), after
   * the enroll failed for a reason that was not the caller's authentication.
   * Only that exact claim, only while no device was recorded for the code.
   */
  readonly restoreEnrollmentCode: (codeSha256: string, usedAt: Date) => Effect.Effect<void, StoreError>;

  /** False when the VM is already a member of a mesh. */
  readonly attachMember: (tenantId: TenantId, member: MeshMemberRow) => Effect.Effect<boolean, StoreError>;
  readonly memberOf: (tenantId: TenantId, vmId: string) => Effect.Effect<Option.Option<MeshMemberRow>, StoreError>;
  readonly listMembers: (tenantId: TenantId, meshId: string) => Effect.Effect<ReadonlyArray<MeshMemberRow>, StoreError>;
  readonly detachMember: (tenantId: TenantId, meshId: string, vmId: string, at: Date) => Effect.Effect<void, StoreError>;

  readonly currentAcl: (tenantId: TenantId, meshId: string) => Effect.Effect<Option.Option<MeshAclVersion>, StoreError>;
  /** False when `version` already exists (a concurrent apply won). */
  readonly insertAcl: (tenantId: TenantId, meshId: string, acl: MeshAclVersion) => Effect.Effect<boolean, StoreError>;
  /** ACL versions created for this mesh since `since` (the per-minute apply budget). */
  readonly aclVersionsSince: (tenantId: TenantId, meshId: string, since: Date) => Effect.Effect<ReadonlyArray<Date>, StoreError>;

  readonly listRules: (tenantId: TenantId, meshId: string) => Effect.Effect<ReadonlyArray<MeshRuleRow>, StoreError>;
  readonly recordRule: (tenantId: TenantId, rule: MeshRuleRow) => Effect.Effect<void, StoreError>;
  readonly markRuleDeleted: (tenantId: TenantId, meshId: string, key: string, at: Date) => Effect.Effect<void, StoreError>;
}

export class MeshStore extends Context.Tag("cmux-vm/MeshStore")<MeshStore, MeshStoreService>() {}

const When = Schema.Union(Schema.DateFromSelf, Schema.Date);
const Count = Schema.Union(Schema.Number, Schema.NumberFromString);

const DeviceRow = Schema.Struct({
  device_cmux_id: Schema.String,
  mesh_cmux_id: Schema.String,
  tunnel_cmux_id: Schema.String,
  name: Schema.String,
  wg_public_key: Schema.String,
  install_public_key: Schema.NullOr(Schema.String),
  created_by: Schema.String,
  created_at: When,
});
const TenantDeviceRow = Schema.Struct({ ...DeviceRow.fields, tenant_id: Schema.String });
const CodeRow = Schema.Struct({
  code_sha256: Schema.String,
  tenant_id: Schema.String,
  mesh_cmux_id: Schema.String,
  created_by: Schema.String,
  created_at: When,
  expires_at: When,
  used_at: Schema.NullOr(When),
});
const MemberRow = Schema.Struct({ mesh_cmux_id: Schema.String, vm_cmux_id: Schema.String, ipv4: Schema.NullOr(Schema.String), attached_at: When });
const AclRuleSchema = Schema.Struct({ src: Schema.Array(Schema.String), dst: Schema.Array(Schema.String), allow: Schema.Array(Schema.String) });
const AclDocumentSchema = Schema.Struct({ rules: Schema.Array(AclRuleSchema) });
const AclRow = Schema.Struct({
  version: Count,
  document: Schema.Union(AclDocumentSchema, Schema.parseJson(AclDocumentSchema)),
  sha256: Schema.String,
  author: Schema.String,
  created_at: When,
});
const RuleRow = Schema.Struct({
  mesh_cmux_id: Schema.String,
  rule_key: Schema.String,
  upstream_rule_id: Schema.String,
  device_cmux_id: Schema.String,
  vm_cmux_id: Schema.String,
  protocol: Schema.NullOr(Schema.Literal("tcp", "udp", "icmp")),
  port: Schema.NullOr(Count),
  created_at: When,
});
const CidrRow = Schema.Struct({ cidr: Schema.String });
const TenantRow = Schema.Struct({ tenant_id: Schema.String });
const WhenRow = Schema.Struct({ created_at: When });
const ClaimedRow = Schema.Struct({ claimed: Count });
const DeviceAddressRow = Schema.Struct({ device_cmux_id: Schema.String, public_ipv6: Schema.String });

const decode = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

const toDevice = (row: typeof DeviceRow.Type): MeshDeviceRow => ({
  deviceId: row.device_cmux_id,
  meshId: row.mesh_cmux_id,
  tunnelId: row.tunnel_cmux_id,
  name: row.name,
  wgPublicKey: row.wg_public_key,
  installPublicKey: row.install_public_key,
  createdBy: row.created_by,
  createdAt: row.created_at,
});
const toMember = (row: typeof MemberRow.Type): MeshMemberRow => ({ meshId: row.mesh_cmux_id, vmId: row.vm_cmux_id, ipv4: row.ipv4, attachedAt: row.attached_at });
const toRule = (row: typeof RuleRow.Type): MeshRuleRow => ({
  meshId: row.mesh_cmux_id,
  key: row.rule_key,
  upstreamRuleId: row.upstream_rule_id,
  deviceId: row.device_cmux_id,
  vmId: row.vm_cmux_id,
  protocol: row.protocol,
  port: row.port,
  createdAt: row.created_at,
});

const DEVICE_COLUMNS = "device_cmux_id, mesh_cmux_id, tunnel_cmux_id, name, wg_public_key, install_public_key, created_by, created_at";
const CODE_COLUMNS = "code_sha256, tenant_id, mesh_cmux_id, created_by, created_at, expires_at, used_at";
const RULE_COLUMNS = "mesh_cmux_id, rule_key, upstream_rule_id, device_cmux_id, vm_cmux_id, protocol, port, created_at";

export const sqlMeshStoreLayer: Layer.Layer<MeshStore, never, SqlClient> = Layer.effect(
  MeshStore,
  Effect.gen(function* () {
    const sql = yield* SqlClient;
    const service: MeshStoreService = {
      claimSlot: (tenantId, meshId, slot, cidr) =>
        sql
          .query(
            "mesh.claimSlot",
            `WITH claimed AS (
               INSERT INTO cmux_vm.mesh_cidrs (mesh_cmux_id, tenant_id, slot, cidr) VALUES ($1, $2, $3, $4)
               ON CONFLICT DO NOTHING RETURNING 1)
             SELECT count(*)::int AS claimed FROM claimed`,
            [meshId, tenantId, slot, cidr],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.claimSlot")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      releaseSlot: (tenantId, meshId) =>
        sql
          .query("mesh.releaseSlot", `DELETE FROM cmux_vm.mesh_cidrs WHERE mesh_cmux_id = $1 AND tenant_id = $2`, [meshId, tenantId])
          .pipe(Effect.asVoid),
      cidrOf: (tenantId, meshId) =>
        sql
          .query("mesh.cidrOf", `SELECT cidr FROM cmux_vm.mesh_cidrs WHERE mesh_cmux_id = $1 AND tenant_id = $2`, [meshId, tenantId])
          .pipe(Effect.flatMap(decode(CidrRow, "mesh.cidrOf")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), (row) => row.cidr))),
      recordDevice: (tenantId, device) =>
        sql
          .query(
            "mesh.recordDevice",
            `INSERT INTO cmux_vm.mesh_devices (device_cmux_id, tenant_id, mesh_cmux_id, tunnel_cmux_id, name, wg_public_key, install_public_key, created_by, created_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::timestamptz)`,
            [
              device.deviceId,
              tenantId,
              device.meshId,
              device.tunnelId,
              device.name,
              device.wgPublicKey,
              device.installPublicKey,
              device.createdBy,
              device.createdAt.toISOString(),
            ],
          )
          .pipe(Effect.asVoid),
      getDevice: (tenantId, deviceId) =>
        sql
          .query(
            "mesh.getDevice",
            `SELECT ${DEVICE_COLUMNS} FROM cmux_vm.mesh_devices WHERE device_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL LIMIT 1`,
            [deviceId, tenantId],
          )
          .pipe(Effect.flatMap(decode(DeviceRow, "mesh.getDevice")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toDevice))),
      getDeviceByTunnel: (tenantId, tunnelId) =>
        sql
          .query(
            "mesh.getDeviceByTunnel",
            `SELECT ${DEVICE_COLUMNS} FROM cmux_vm.mesh_devices WHERE tunnel_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL LIMIT 1`,
            [tunnelId, tenantId],
          )
          .pipe(Effect.flatMap(decode(DeviceRow, "mesh.getDeviceByTunnel")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toDevice))),
      listDevices: (tenantId, meshId) =>
        sql
          .query(
            "mesh.listDevices",
            `SELECT ${DEVICE_COLUMNS} FROM cmux_vm.mesh_devices
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL ORDER BY created_at, device_cmux_id`,
            [meshId, tenantId],
          )
          .pipe(Effect.flatMap(decode(DeviceRow, "mesh.listDevices")), Effect.map((rows) => rows.map(toDevice))),
      findDeviceForSignedRequest: (deviceId) =>
        sql
          .query(
            "mesh.findDeviceForSignedRequest",
            `SELECT tenant_id, ${DEVICE_COLUMNS} FROM cmux_vm.mesh_devices WHERE device_cmux_id = $1 AND deleted_at IS NULL LIMIT 1`,
            [deviceId],
          )
          .pipe(
            Effect.flatMap(decode(TenantDeviceRow, "mesh.findDeviceForSignedRequest")),
            Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), (row) => ({ ...toDevice(row), tenantId: TenantIdBrand.make(row.tenant_id) }))),
          ),
      markDeviceDeleted: (tenantId, deviceId, at) =>
        sql
          .query(
            "mesh.markDeviceDeleted",
            `UPDATE cmux_vm.mesh_devices SET deleted_at = $3::timestamptz WHERE device_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL`,
            [deviceId, tenantId, at.toISOString()],
          )
          .pipe(Effect.asVoid),
      listDevicesCreatedBy: (tenantId, createdBy) =>
        sql
          .query(
            "mesh.listDevicesCreatedBy",
            `SELECT ${DEVICE_COLUMNS} FROM cmux_vm.mesh_devices
              WHERE tenant_id = $1 AND created_by = $2 AND deleted_at IS NULL ORDER BY created_at, device_cmux_id`,
            [tenantId, createdBy],
          )
          .pipe(Effect.flatMap(decode(DeviceRow, "mesh.listDevicesCreatedBy")), Effect.map((rows) => rows.map(toDevice))),
      listTenantsWithDevicesCreatedBy: (createdBy) =>
        sql
          .query(
            "mesh.listTenantsWithDevicesCreatedBy",
            `SELECT DISTINCT tenant_id FROM cmux_vm.mesh_devices WHERE created_by = $1 AND deleted_at IS NULL ORDER BY tenant_id`,
            [createdBy],
          )
          .pipe(
            Effect.flatMap(decode(TenantRow, "mesh.listTenantsWithDevicesCreatedBy")),
            Effect.map((rows) => rows.map((row) => TenantIdBrand.make(row.tenant_id))),
          ),
      updateDeviceKey: (tenantId, deviceId, wgPublicKey, at) =>
        sql
          .query(
            "mesh.updateDeviceKey",
            `WITH updated AS (
               UPDATE cmux_vm.mesh_devices AS device SET wg_public_key = $3, key_rotated_at = $4::timestamptz
                WHERE device.device_cmux_id = $1 AND device.tenant_id = $2 AND device.deleted_at IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM cmux_vm.mesh_devices other
                     WHERE other.mesh_cmux_id = device.mesh_cmux_id AND other.wg_public_key = $3
                       AND other.deleted_at IS NULL AND other.device_cmux_id <> device.device_cmux_id)
               RETURNING 1)
             SELECT count(*)::int AS claimed FROM updated`,
            [deviceId, tenantId, wgPublicKey, at.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.updateDeviceKey")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      setDeviceAddress: (tenantId, deviceId, publicIpv6, at) =>
        sql
          .query(
            "mesh.setDeviceAddress",
            `WITH updated AS (
               UPDATE cmux_vm.mesh_devices SET public_ipv6 = $3, public_ipv6_at = $4::timestamptz
                WHERE device_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL
               RETURNING 1)
             SELECT count(*)::int AS claimed FROM updated`,
            [deviceId, tenantId, publicIpv6, at.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.setDeviceAddress")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      deviceAddresses: (tenantId, meshId) =>
        sql
          .query(
            "mesh.deviceAddresses",
            `SELECT device_cmux_id, public_ipv6 FROM cmux_vm.mesh_devices
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL AND public_ipv6 IS NOT NULL
              ORDER BY device_cmux_id`,
            [meshId, tenantId],
          )
          .pipe(
            Effect.flatMap(decode(DeviceAddressRow, "mesh.deviceAddresses")),
            Effect.map((rows) => new Map(rows.map((row) => [row.device_cmux_id, row.public_ipv6]))),
          ),
      claimSignedRequest: (tenantId, messageSha256, purpose, expiresAt, now) =>
        sql
          .query(
            "mesh.claimSignedRequest",
            `WITH pruned AS (
               DELETE FROM cmux_vm.mesh_signed_requests
                WHERE message_sha256 IN (SELECT message_sha256 FROM cmux_vm.mesh_signed_requests WHERE expires_at < $5::timestamptz LIMIT 100)),
             claimed AS (
               INSERT INTO cmux_vm.mesh_signed_requests (message_sha256, tenant_id, purpose, expires_at)
               VALUES ($1, $2, $3, $4::timestamptz)
               ON CONFLICT DO NOTHING RETURNING 1)
             SELECT count(*)::int AS claimed FROM claimed`,
            [messageSha256, tenantId, purpose, expiresAt.toISOString(), now.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.claimSignedRequest")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      insertEnrollmentCode: (code) =>
        sql
          .query(
            "mesh.insertEnrollmentCode",
            `INSERT INTO cmux_vm.mesh_enrollment_codes (code_sha256, tenant_id, mesh_cmux_id, created_by, created_at, expires_at)
             VALUES ($1, $2, $3, $4, $5::timestamptz, $6::timestamptz)`,
            [code.codeSha256, code.tenantId, code.meshId, code.createdBy, code.createdAt.toISOString(), code.expiresAt.toISOString()],
          )
          .pipe(Effect.asVoid),
      enrollmentCodesSince: (tenantId, meshId, since) =>
        sql
          .query(
            "mesh.enrollmentCodesSince",
            `SELECT created_at FROM cmux_vm.mesh_enrollment_codes
              WHERE tenant_id = $1 AND mesh_cmux_id = $2 AND created_at > $3::timestamptz ORDER BY created_at`,
            [tenantId, meshId, since.toISOString()],
          )
          .pipe(Effect.flatMap(decode(WhenRow, "mesh.enrollmentCodesSince")), Effect.map((rows) => rows.map((row) => row.created_at))),
      findEnrollmentCode: (codeSha256, meshId, now) =>
        sql
          .query(
            "mesh.findEnrollmentCode",
            `SELECT ${CODE_COLUMNS} FROM cmux_vm.mesh_enrollment_codes
              WHERE code_sha256 = $1 AND mesh_cmux_id = $2 AND used_at IS NULL AND expires_at > $3::timestamptz LIMIT 1`,
            [codeSha256, meshId, now.toISOString()],
          )
          .pipe(
            Effect.flatMap(decode(CodeRow, "mesh.findEnrollmentCode")),
            Effect.map((rows) =>
              Option.map(Option.fromNullable(rows[0]), (row) => ({
                codeSha256: row.code_sha256,
                tenantId: TenantIdBrand.make(row.tenant_id),
                meshId: row.mesh_cmux_id,
                createdBy: row.created_by,
                createdAt: row.created_at,
                expiresAt: row.expires_at,
                usedAt: row.used_at,
              })),
            ),
          ),
      consumeEnrollmentCode: (codeSha256, meshId, now) =>
        sql
          .query(
            "mesh.consumeEnrollmentCode",
            `WITH used AS (
               UPDATE cmux_vm.mesh_enrollment_codes SET used_at = $3::timestamptz
                WHERE code_sha256 = $1 AND mesh_cmux_id = $2 AND used_at IS NULL AND expires_at > $3::timestamptz
               RETURNING 1)
             SELECT count(*)::int AS claimed FROM used`,
            [codeSha256, meshId, now.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.consumeEnrollmentCode")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      recordEnrollmentCodeDevice: (codeSha256, deviceId) =>
        sql
          .query("mesh.recordEnrollmentCodeDevice", `UPDATE cmux_vm.mesh_enrollment_codes SET device_cmux_id = $2 WHERE code_sha256 = $1`, [codeSha256, deviceId])
          .pipe(Effect.asVoid),
      burnEnrollmentCode: (codeSha256, now) =>
        sql
          .query(
            "mesh.burnEnrollmentCode",
            `UPDATE cmux_vm.mesh_enrollment_codes
                SET used_at = COALESCE(used_at, $2::timestamptz),
                    expires_at = LEAST(expires_at, GREATEST($2::timestamptz, created_at + interval '1 millisecond'))
              WHERE code_sha256 = $1 AND device_cmux_id IS NULL`,
            [codeSha256, now.toISOString()],
          )
          .pipe(Effect.asVoid),
      restoreEnrollmentCode: (codeSha256, usedAt) =>
        sql
          .query(
            "mesh.restoreEnrollmentCode",
            `UPDATE cmux_vm.mesh_enrollment_codes SET used_at = NULL
              WHERE code_sha256 = $1 AND used_at = $2::timestamptz AND device_cmux_id IS NULL`,
            [codeSha256, usedAt.toISOString()],
          )
          .pipe(Effect.asVoid),
      attachMember: (tenantId, member) =>
        sql
          .query(
            "mesh.attachMember",
            `WITH claimed AS (
               INSERT INTO cmux_vm.mesh_members (mesh_cmux_id, vm_cmux_id, tenant_id, ipv4, attached_at)
               VALUES ($1, $2, $3, $4, $5::timestamptz)
               ON CONFLICT DO NOTHING RETURNING 1)
             SELECT count(*)::int AS claimed FROM claimed`,
            [member.meshId, member.vmId, tenantId, member.ipv4, member.attachedAt.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.attachMember")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      memberOf: (tenantId, vmId) =>
        sql
          .query(
            "mesh.memberOf",
            `SELECT mesh_cmux_id, vm_cmux_id, ipv4, attached_at FROM cmux_vm.mesh_members
              WHERE vm_cmux_id = $1 AND tenant_id = $2 AND detached_at IS NULL LIMIT 1`,
            [vmId, tenantId],
          )
          .pipe(Effect.flatMap(decode(MemberRow, "mesh.memberOf")), Effect.map((rows) => Option.map(Option.fromNullable(rows[0]), toMember))),
      listMembers: (tenantId, meshId) =>
        sql
          .query(
            "mesh.listMembers",
            `SELECT mesh_cmux_id, vm_cmux_id, ipv4, attached_at FROM cmux_vm.mesh_members
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND detached_at IS NULL ORDER BY attached_at, vm_cmux_id`,
            [meshId, tenantId],
          )
          .pipe(Effect.flatMap(decode(MemberRow, "mesh.listMembers")), Effect.map((rows) => rows.map(toMember))),
      detachMember: (tenantId, meshId, vmId, at) =>
        sql
          .query(
            "mesh.detachMember",
            `UPDATE cmux_vm.mesh_members SET detached_at = $4::timestamptz
              WHERE mesh_cmux_id = $1 AND vm_cmux_id = $2 AND tenant_id = $3 AND detached_at IS NULL`,
            [meshId, vmId, tenantId, at.toISOString()],
          )
          .pipe(Effect.asVoid),
      currentAcl: (tenantId, meshId) =>
        sql
          .query(
            "mesh.currentAcl",
            `SELECT version, document::text AS document, sha256, author, created_at FROM cmux_vm.mesh_acl_versions
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 ORDER BY version DESC LIMIT 1`,
            [meshId, tenantId],
          )
          .pipe(
            Effect.flatMap(decode(AclRow, "mesh.currentAcl")),
            Effect.map((rows) =>
              Option.map(Option.fromNullable(rows[0]), (row) => ({
                version: row.version,
                document: row.document,
                sha256: row.sha256,
                author: row.author,
                createdAt: row.created_at,
              })),
            ),
          ),
      insertAcl: (tenantId, meshId, acl) =>
        sql
          .query(
            "mesh.insertAcl",
            `WITH claimed AS (
               INSERT INTO cmux_vm.mesh_acl_versions (mesh_cmux_id, tenant_id, version, document, sha256, author, created_at)
               VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7::timestamptz)
               ON CONFLICT DO NOTHING RETURNING 1)
             SELECT count(*)::int AS claimed FROM claimed`,
            [meshId, tenantId, acl.version, JSON.stringify(acl.document), acl.sha256, acl.author, acl.createdAt.toISOString()],
          )
          .pipe(Effect.flatMap(decode(ClaimedRow, "mesh.insertAcl")), Effect.map((rows) => (rows[0]?.claimed ?? 0) > 0)),
      aclVersionsSince: (tenantId, meshId, since) =>
        sql
          .query(
            "mesh.aclVersionsSince",
            `SELECT created_at FROM cmux_vm.mesh_acl_versions
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND created_at > $3::timestamptz ORDER BY created_at`,
            [meshId, tenantId, since.toISOString()],
          )
          .pipe(Effect.flatMap(decode(WhenRow, "mesh.aclVersionsSince")), Effect.map((rows) => rows.map((row) => row.created_at))),
      listRules: (tenantId, meshId) =>
        sql
          .query(
            "mesh.listRules",
            `SELECT ${RULE_COLUMNS} FROM cmux_vm.mesh_firewall_rules
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND deleted_at IS NULL ORDER BY rule_key`,
            [meshId, tenantId],
          )
          .pipe(Effect.flatMap(decode(RuleRow, "mesh.listRules")), Effect.map((rows) => rows.map(toRule))),
      recordRule: (tenantId, rule) =>
        sql
          .query(
            "mesh.recordRule",
            `INSERT INTO cmux_vm.mesh_firewall_rules
               (mesh_cmux_id, tenant_id, rule_key, upstream_rule_id, device_cmux_id, vm_cmux_id, protocol, port, created_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::timestamptz)`,
            [rule.meshId, tenantId, rule.key, rule.upstreamRuleId, rule.deviceId, rule.vmId, rule.protocol, rule.port, rule.createdAt.toISOString()],
          )
          .pipe(Effect.asVoid),
      markRuleDeleted: (tenantId, meshId, key, at) =>
        sql
          .query(
            "mesh.markRuleDeleted",
            `UPDATE cmux_vm.mesh_firewall_rules SET deleted_at = $4::timestamptz
              WHERE mesh_cmux_id = $1 AND tenant_id = $2 AND rule_key = $3 AND deleted_at IS NULL`,
            [meshId, tenantId, key, at.toISOString()],
          )
          .pipe(Effect.asVoid),
    };
    return service;
  }),
);
