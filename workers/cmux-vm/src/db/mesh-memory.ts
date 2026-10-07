/**
 * The mesh tables in memory, with the same keys and uniqueness rules as
 * migrations/0004_cmux_vm_mesh.sql. For tests and for the M1c proof server,
 * which runs the real handlers without a database.
 */
import { Effect, Layer, Option } from "effect";
import { MeshStore, type MeshAclVersion, type MeshDeviceRow, type MeshMemberRow, type MeshRuleRow } from "./mesh.ts";

export function makeMemoryMeshStore() {
  const slots = new Map<number, { readonly tenantId: string; readonly meshId: string; readonly cidr: string }>();
  const devices: Array<MeshDeviceRow & { readonly tenantId: string; deletedAt: Date | null }> = [];
  const members: Array<MeshMemberRow & { readonly tenantId: string; detachedAt: Date | null }> = [];
  const acls: Array<MeshAclVersion & { readonly tenantId: string; readonly meshId: string }> = [];
  const rules: Array<MeshRuleRow & { readonly tenantId: string; deletedAt: Date | null }> = [];

  const layer = Layer.succeed(MeshStore, {
    claimSlot: (tenantId, meshId, slot, cidr) =>
      Effect.sync(() => {
        if (slots.has(slot) || [...slots.values()].some((entry) => entry.meshId === meshId)) return false;
        slots.set(slot, { tenantId, meshId, cidr });
        return true;
      }),
    releaseSlot: (tenantId, meshId) =>
      Effect.sync(() => {
        for (const [slot, entry] of slots) if (entry.tenantId === tenantId && entry.meshId === meshId) slots.delete(slot);
      }),
    cidrOf: (tenantId, meshId) =>
      Effect.sync(() =>
        Option.map(
          Option.fromNullable([...slots.values()].find((entry) => entry.tenantId === tenantId && entry.meshId === meshId)),
          (entry) => entry.cidr,
        ),
      ),
    recordDevice: (tenantId, device) => Effect.sync(() => void devices.push({ ...device, tenantId, deletedAt: null })),
    getDevice: (tenantId, deviceId) =>
      Effect.sync(() => Option.fromNullable(devices.find((row) => row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null))),
    getDeviceByTunnel: (tenantId, tunnelId) =>
      Effect.sync(() => Option.fromNullable(devices.find((row) => row.tenantId === tenantId && row.tunnelId === tunnelId && row.deletedAt === null))),
    listDevices: (tenantId, meshId) =>
      Effect.sync(() => devices.filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.deletedAt === null)),
    markDeviceDeleted: (tenantId, deviceId, at) =>
      Effect.sync(() => {
        for (const row of devices) if (row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null) row.deletedAt = at;
      }),
    attachMember: (tenantId, member) =>
      Effect.sync(() => {
        if (members.some((row) => row.vmId === member.vmId && row.detachedAt === null)) return false;
        members.push({ ...member, tenantId, detachedAt: null });
        return true;
      }),
    memberOf: (tenantId, vmId) =>
      Effect.sync(() => Option.fromNullable(members.find((row) => row.tenantId === tenantId && row.vmId === vmId && row.detachedAt === null))),
    listMembers: (tenantId, meshId) =>
      Effect.sync(() => members.filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.detachedAt === null)),
    detachMember: (tenantId, meshId, vmId, at) =>
      Effect.sync(() => {
        for (const row of members) {
          if (row.tenantId === tenantId && row.meshId === meshId && row.vmId === vmId && row.detachedAt === null) row.detachedAt = at;
        }
      }),
    currentAcl: (tenantId, meshId) =>
      Effect.sync(() =>
        Option.fromNullable(
          acls.filter((row) => row.tenantId === tenantId && row.meshId === meshId).sort((a, b) => b.version - a.version)[0],
        ),
      ),
    insertAcl: (tenantId, meshId, acl) =>
      Effect.sync(() => {
        if (acls.some((row) => row.meshId === meshId && row.version === acl.version)) return false;
        acls.push({ ...acl, tenantId, meshId });
        return true;
      }),
    aclVersionsSince: (tenantId, meshId, since) =>
      Effect.sync(() =>
        acls.filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.createdAt > since).map((row) => row.createdAt),
      ),
    listRules: (tenantId, meshId) =>
      Effect.sync(() =>
        rules
          .filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.deletedAt === null)
          .sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)),
      ),
    recordRule: (tenantId, rule) => Effect.sync(() => void rules.push({ ...rule, tenantId, deletedAt: null })),
    markRuleDeleted: (tenantId, meshId, key, at) =>
      Effect.sync(() => {
        for (const row of rules) if (row.tenantId === tenantId && row.meshId === meshId && row.key === key && row.deletedAt === null) row.deletedAt = at;
      }),
  });

  return { layer, devices, members, acls, rules, slots };
}
