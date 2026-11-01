/**
 * The mesh tables in memory, with the same keys and uniqueness rules as
 * migrations/0004_cmux_vm_mesh.sql. For tests and for the M1c proof server,
 * which runs the real handlers without a database.
 */
import { Effect, Layer, Option } from "effect";
import { TenantId } from "../lib/ids.ts";
import type { OverlayServerRow } from "./overlay-servers.ts";
import type { OverlayServerCodeRow } from "./overlay-server-codes.ts";
import { MeshStore, type MeshAclVersion, type MeshDeviceRow, type MeshEnrollmentCodeRow, type MeshMemberRow, type MeshRuleRow } from "./mesh.ts";

/** A code row as tests may age it (expiresAt is writable here only). */
export type MemoryEnrollmentCode = Omit<MeshEnrollmentCodeRow, "expiresAt" | "usedAt"> & { expiresAt: Date; usedAt: Date | null; deviceId: string | null };

export function makeMemoryMeshStore() {
  const slots = new Map<number, { readonly tenantId: string; readonly meshId: string; readonly cidr: string }>();
  const devices: Array<MeshDeviceRow & { readonly tenantId: string; deletedAt: Date | null }> = [];
  const servers: Array<OverlayServerRow & { readonly tenantId: string; revokedAt: Date | null }> = [];
  /** Published public IPv6 addresses (migration 0009), by device id. */
  const addresses = new Map<string, string>();
  const addressTimes = new Map<string, Date>();
  const members: Array<MeshMemberRow & { readonly tenantId: string; detachedAt: Date | null }> = [];
  const acls: Array<MeshAclVersion & { readonly tenantId: string; readonly meshId: string }> = [];
  const rules: Array<MeshRuleRow & { readonly tenantId: string; deletedAt: Date | null }> = [];
  const signed = new Map<string, Date>();
  const codes: Array<MemoryEnrollmentCode> = [];
  const serverCodes: Array<OverlayServerCodeRow> = [];

  const layer = Layer.succeed(MeshStore, {
    insertOverlayServerCode: (row) => Effect.sync(() => { serverCodes.push({ ...row }); }),
    findOverlayServerCode: (hash) => Effect.sync(() => Option.fromNullable(serverCodes.find((row) => row.codeSha256 === hash))),
    recentOverlayServerCodes: (tenant, mesh, since) => Effect.sync(() => serverCodes.filter((row) => row.tenantId === tenant && row.meshId === mesh && row.createdAt > since)),
    burnOverlayServerCode: (hash, at) => Effect.sync(() => { const i = serverCodes.findIndex((row) => row.codeSha256 === hash && row.usedAt === null); const row = serverCodes[i]; if (row !== undefined) serverCodes[i] = { ...row, burnedAt: row.burnedAt ?? at }; }),
    redeemOverlayServerCode: (tenant, hash, mesh, at) => Effect.sync(() => {
      const i = serverCodes.findIndex((row) => row.tenantId === tenant && row.codeSha256 === hash && row.meshId === mesh && row.burnedAt === null && row.expiresAt > at);
      const code = serverCodes[i]; if (code === undefined) return false;
      const existing = servers.find((row) => row.deviceId === code.deviceId);
      if (existing !== undefined) {
        if (existing.revokedAt !== null || existing.tenantId !== tenant || existing.meshId !== mesh || existing.createdBy !== code.createdBy || existing.name !== code.name || existing.wgPublicKey !== code.wgPublicKey || existing.installPublicKey !== code.installPublicKey) return false;
      } else {
        if (code.usedAt !== null || servers.some((row) => row.revokedAt === null && row.tenantId === tenant && row.meshId === mesh && (row.wgPublicKey === code.wgPublicKey || row.installPublicKey === code.installPublicKey))) return false;
        servers.push({ deviceId: code.deviceId, meshId: mesh, name: code.name, wgPublicKey: code.wgPublicKey, installPublicKey: code.installPublicKey, createdBy: code.createdBy, createdAt: at, tenantId: tenant, revokedAt: null });
      }
      serverCodes[i] = { ...code, usedAt: code.usedAt ?? at }; return true;
    }),
    recordOverlayServer: (tenantId, row) => Effect.sync(() => {
      if (servers.some((other) => other.deviceId === row.deviceId || (other.revokedAt === null && other.tenantId === tenantId && other.meshId === row.meshId && (other.wgPublicKey === row.wgPublicKey || other.installPublicKey === row.installPublicKey)))) return false;
      servers.push({ ...row, tenantId, revokedAt: null }); return true;
    }),
    getOverlayServer: (tenant, id) => Effect.sync(() => Option.fromNullable(servers.find((row) => row.tenantId === tenant && row.deviceId === id && row.revokedAt === null))),
    findOverlayServerForSignature: (id) => Effect.sync(() => Option.map(Option.fromNullable(servers.find((row) => row.deviceId === id && row.revokedAt === null)), (row) => ({ ...row, tenantId: TenantId.make(row.tenantId) }))),
    listOverlayServers: (tenant, mesh) => Effect.sync(() => servers.filter((row) => row.tenantId === tenant && row.meshId === mesh && row.revokedAt === null).sort((a, b) => a.deviceId.localeCompare(b.deviceId))),
    revokeOverlayServer: (tenant, id, at) => Effect.sync(() => { for (const row of servers) if (row.tenantId === tenant && row.deviceId === id && row.revokedAt === null) row.revokedAt = at; }),
    revokeOverlayServersCreatedBy: (tenant, createdBy, cutoff, at) => Effect.sync(() => {
      const revoked = servers.filter((row) => row.tenantId === tenant && row.createdBy === createdBy && row.revokedAt === null && (cutoff === null || row.createdAt.getTime() <= cutoff.getTime()));
      for (const row of revoked) row.revokedAt = at;
      return revoked.map(({ tenantId: _tenant, revokedAt: _revoked, ...row }) => row);
    }),
    listTenantsWithOverlayServersCreatedBy: (createdBy) => Effect.sync(() => [...new Set(servers.filter((row) => row.createdBy === createdBy && row.revokedAt === null).map((row) => row.tenantId))].sort().map((id) => TenantId.make(id))),
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
    findDeviceForSignedRequest: (deviceId) =>
      Effect.sync(() =>
        Option.map(Option.fromNullable(devices.find((row) => row.deviceId === deviceId && row.deletedAt === null)), (row) => ({
          ...row,
          tenantId: TenantId.make(row.tenantId),
        })),
      ),
    markDeviceDeleted: (tenantId, deviceId, at) =>
      Effect.sync(() => {
        for (const row of devices) if (row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null) row.deletedAt = at;
      }),
    listDevicesCreatedBy: (tenantId, createdBy) =>
      Effect.sync(() => devices.filter((row) => row.tenantId === tenantId && row.createdBy === createdBy && row.deletedAt === null)),
    listTenantsWithDevicesCreatedBy: (createdBy) =>
      Effect.sync(() => [...new Set(devices.filter((row) => row.createdBy === createdBy && row.deletedAt === null).map((row) => row.tenantId))].sort().map((id) => TenantId.make(id))),
    updateDeviceKey: (tenantId, deviceId, wgPublicKey, _at) =>
      Effect.sync(() => {
        const index = devices.findIndex((row) => row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null);
        const current = devices[index];
        if (current === undefined) return false;
        if (devices.some((row) => row.meshId === current.meshId && row.wgPublicKey === wgPublicKey && row.deletedAt === null && row.deviceId !== deviceId)) return false;
        devices[index] = { ...current, wgPublicKey };
        return true;
      }),
    setDeviceAddress: (tenantId, deviceId, publicIpv6, at) =>
      Effect.sync(() => {
        const live = devices.some((row) => row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null);
        if (!live) return false;
        if (at === null) addressTimes.delete(deviceId);
        else addressTimes.set(deviceId, at);
        if (publicIpv6 === null) addresses.delete(deviceId);
        else addresses.set(deviceId, publicIpv6);
        return true;
      }),
    getDeviceAddress: (tenantId, deviceId) =>
      Effect.sync(() =>
        devices.some((row) => row.tenantId === tenantId && row.deviceId === deviceId && row.deletedAt === null)
          ? Option.some({ publicIpv6: addresses.get(deviceId) ?? null, at: addressTimes.get(deviceId) ?? null })
          : Option.none(),
      ),
    deviceAddresses: (tenantId, meshId) =>
      Effect.sync(() => {
        const out = new Map<string, string>();
        const live = devices
          .filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.deletedAt === null)
          .map((row) => row.deviceId)
          .sort();
        for (const deviceId of live) {
          const address = addresses.get(deviceId);
          if (address !== undefined) out.set(deviceId, address);
        }
        return out;
      }),
    claimSignedRequest: (_tenantId, messageSha256, _purpose, expiresAt, now) =>
      Effect.sync(() => {
        for (const [hash, expiry] of signed) if (expiry < now) signed.delete(hash);
        if (signed.has(messageSha256)) return false;
        signed.set(messageSha256, expiresAt);
        return true;
      }),
    insertEnrollmentCode: (code) => Effect.sync(() => void codes.push({ ...code, usedAt: null, deviceId: null })),
    enrollmentCodesSince: (tenantId, meshId, since) =>
      Effect.sync(() => codes.filter((row) => row.tenantId === tenantId && row.meshId === meshId && row.createdAt > since).map((row) => row.createdAt)),
    findEnrollmentCode: (codeSha256, meshId, now) =>
      Effect.sync(() =>
        Option.map(
          Option.fromNullable(codes.find((row) => row.codeSha256 === codeSha256 && row.meshId === meshId && row.usedAt === null && row.expiresAt > now)),
          (row): MeshEnrollmentCodeRow => ({ ...row }),
        ),
      ),
    consumeEnrollmentCode: (codeSha256, meshId, now) =>
      Effect.sync(() => {
        const row = codes.find((candidate) => candidate.codeSha256 === codeSha256 && candidate.meshId === meshId && candidate.usedAt === null && candidate.expiresAt > now);
        if (row === undefined) return false;
        row.usedAt = now;
        return true;
      }),
    recordEnrollmentCodeDevice: (codeSha256, deviceId) =>
      Effect.sync(() => {
        for (const row of codes) if (row.codeSha256 === codeSha256) row.deviceId = deviceId;
      }),
    burnEnrollmentCode: (codeSha256, now) =>
      Effect.sync(() => {
        for (const row of codes) {
          if (row.codeSha256 !== codeSha256 || row.deviceId !== null) continue;
          row.usedAt = row.usedAt ?? now;
          const floor = new Date(Math.max(now.getTime(), row.createdAt.getTime() + 1));
          if (floor < row.expiresAt) row.expiresAt = floor;
        }
      }),
    restoreEnrollmentCode: (codeSha256, usedAt) =>
      Effect.sync(() => {
        for (const row of codes) {
          if (row.codeSha256 === codeSha256 && row.deviceId === null && row.usedAt !== null && row.usedAt.getTime() === usedAt.getTime()) row.usedAt = null;
        }
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
    updateMemberAddress: (tenantId, member, ipv4) => Effect.sync(() => {
      const index = members.findIndex((row) => row.tenantId === tenantId && row.meshId === member.meshId && row.vmId === member.vmId
        && row.detachedAt === null && row.attachedAt.getTime() === member.attachedAt.getTime() && row.ipv4 === member.ipv4);
      if (index < 0) return false;
      members[index] = { ...members[index]!, ipv4 };
      return true;
    }),
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

  return {
    layer,
    devices,
    members,
    acls,
    rules,
    slots,
    /** The stored enrollment codes (hashes only); tests may move `expiresAt`. */
    enrollmentCodes: (): ReadonlyArray<MemoryEnrollmentCode> => codes,
    overlayServerCodes: (): ReadonlyArray<OverlayServerCodeRow> => serverCodes,
  };
}
