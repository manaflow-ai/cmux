/**
 * Mesh networking parity endpoints (cx-0op; contract src/api/mesh-network.ts).
 *
 * Same order as src/handlers/mesh.ts on every route: the experiment gate
 * (404), the scope (403), the rate limit (429), then ownership through the
 * caller's tenant (another tenant's mesh or device is 404). Renames change
 * only cmux's own names: the provider network and tunnel keep their
 * cmux-managed names, so nothing a tenant types reaches the provider. The
 * firewall reads come from the mesh's own rule table and ACL; the one provider
 * read (device addresses) goes through proofs of the tenant's own devices.
 */
import { HttpApiBuilder } from "@effect/platform";
import { Effect, Option } from "effect";
import { CmuxVmApi } from "../api.ts";
import { MeshAclEvaluation, MeshAddressList, MeshFirewallRuleList, TunnelList } from "../api/mesh-network.ts";
import { MeshStore, type MeshDeviceRow, type MeshRuleRow } from "../db/mesh.ts";
import { OwnershipStore } from "../db/stores.ts";
import { carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { BadRequest, NotFound, unavailable } from "../errors.ts";
import { parseDeviceId, parseMeshId, parseTunnelId, parseVmId, type DeviceId, type MeshId, type TunnelId, type VmId } from "../lib/ids.ts";
import { isAddressRuleKey } from "../mesh/acl.ts";
import { allowedBy, firstAllowingRule } from "../mesh/acl-evaluate.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import { enrolledBy, isTenantAdmin } from "../proofs/device-owner.ts";
import { meshDeviceTunnels } from "../proofs/mesh-device-tunnel.ts";
import { UpstreamMesh } from "../upstream/mesh.ts";
import { audited, dependencyDown } from "./common.ts";
import { compileFor, compiled, EMPTY_ACL, requireAdmin, toDevice, toMesh, withMeshCaller, withOwnedDevice, withOwnedMesh } from "./mesh.ts";

const meshNotFound = () => new NotFound({ message: "Mesh not found" });
const deviceNotFound = () => new NotFound({ message: "Device not found" });
const ruleNotFound = () => new NotFound({ message: "Firewall rule not found" });

// Rows hold ids this service minted and validated on write; decode them back to their brands.
const MeshId_ = (id: string): MeshId => Option.getOrThrow(parseMeshId(id));
const DeviceId_ = (id: string): DeviceId => Option.getOrThrow(parseDeviceId(id));
const TunnelId_ = (id: string): TunnelId => Option.getOrThrow(parseTunnelId(id));
const VmId_ = (id: string): VmId => Option.getOrThrow(parseVmId(id));

const inAllowlist = (principal: Principal, ...ids: ReadonlyArray<string>): boolean =>
  principal.resourceAllowlist === null || ids.some((id) => principal.resourceAllowlist?.has(id) === true);

/** The devices `principal` may see: inside its allowlist, and its own unless it is a tenant admin (as GET .../devices). */
const visibleDevices = (principal: Principal, rows: ReadonlyArray<MeshDeviceRow>) =>
  Effect.gen(function* () {
    const allowed = rows.filter((row) => inAllowlist(principal, row.deviceId, row.tunnelId));
    const own = allowed.filter((row) => enrolledBy(principal, row));
    if (own.length === allowed.length) return allowed;
    const admin = yield* isTenantAdmin(principal).pipe(Effect.mapError(() => unavailable()));
    return admin ? allowed : own;
  });

/** A rule's public id: derived from its mesh and key, so it names no provider id and no device address. */
const ruleIdOf = (row: MeshRuleRow) => Effect.map(sha256Hex(`${row.meshId}\n${row.key}`), (hash) => `fwr_${hash.slice(0, 32)}`);

const toRule = (row: MeshRuleRow) =>
  Effect.map(ruleIdOf(row), (id) => ({
    id,
    meshId: MeshId_(row.meshId),
    deviceId: DeviceId_(row.deviceId),
    vmId: VmId_(row.vmId),
    source: isAddressRuleKey(row.key) ? ("address" as const) : ("tunnel" as const),
    protocol: row.protocol,
    port: row.port,
    createdAt: row.createdAt.toISOString(),
  }));

const meshRules = (tenantId: Principal["tenantId"], meshId: string) =>
  Effect.gen(function* () {
    const rows = yield* (yield* MeshStore).listRules(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listRules")));
    const rules = yield* Effect.forEach(
      rows.filter((row) => row.meshId === meshId),
      toRule,
    );
    return [...rules].sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  });

const RULE_ID = /^fwr_[0-9a-f]{32}$/u;

export const meshNetworkHandlers = HttpApiBuilder.group(CmuxVmApi, "meshNetwork", (handlers) =>
  handlers
    .handle("updateMesh", ({ path, payload }) =>
      withOwnedMesh(path.meshId, "mesh:write", "write", (caller, mesh) =>
        audited(
          "mesh.update",
          mesh.value,
          Effect.gen(function* () {
            const tenantId = caller.value.tenantId;
            yield* requireAdmin(caller.value, "mesh:write");
            const ownership = yield* OwnershipStore;
            const store = yield* MeshStore;
            const renamed = yield* ownership
              .setDisplayName(tenantId, "mesh", mesh.value, payload.displayName)
              .pipe(Effect.catchAll(dependencyDown("ownership.setDisplayName")));
            if (!renamed) return yield* Effect.fail(meshNotFound());
            const row = yield* ownership.find(tenantId, "mesh", mesh.value).pipe(Effect.catchAll(dependencyDown("ownership.find")));
            if (Option.isNone(row)) return yield* Effect.fail(meshNotFound());
            const cidr = yield* store.cidrOf(tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.cidrOf")));
            return toMesh(mesh.value, row.value.displayName, Option.getOrElse(cidr, () => ""), row.value.createdAt);
          }),
        ),
      ),
    )
    .handle("listMeshAddresses", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:read", "read", (caller, mesh, proofs) =>
        Effect.gen(function* () {
          const principal = caller.value;
          const store = yield* MeshStore;
          const upstream = yield* UpstreamMesh;
          const members = yield* store.listMembers(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listMembers")));
          const devices = yield* store.listDevices(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
          const visible = yield* visibleDevices(principal, devices);
          const tunnels = yield* meshDeviceTunnels(caller, mesh, proofs.owns, visible.map((row) => row.deviceId)).pipe(
            Effect.catchAll(dependencyDown("mesh.deviceTunnels")),
          );
          const addresses = yield* upstream.listDeviceAddresses(mesh, { owns: proofs.owns, scope: proofs.scope }, tunnels).pipe(Effect.mapError(() => unavailable()));
          const vms = members
            .filter((member) => member.meshId === mesh.value && inAllowlist(principal, member.vmId))
            .map((member) => ({ kind: "vm" as const, id: member.vmId, ipv4: member.ipv4 }));
          const deviceAddresses = visible.map((row) => ({ kind: "device" as const, id: row.deviceId, ipv4: addresses.get(row.deviceId) ?? null }));
          return new MeshAddressList({ meshId: MeshId_(mesh.value), items: [...vms, ...deviceAddresses] });
        }),
      ),
    )
    .handle("listTunnels", () =>
      withMeshCaller("mesh:read", "read", (caller) =>
        Effect.gen(function* () {
          const principal = caller.value;
          const ownership = yield* OwnershipStore;
          const store = yield* MeshStore;
          const meshes = yield* ownership
            .listPage(principal.tenantId, "mesh", { limit: 100, after: null, only: principal.resourceAllowlist, labels: null })
            .pipe(Effect.catchAll(dependencyDown("ownership.list")));
          const reachable = meshes.filter((row) => carriesRequiredLabels(principal, row.labels));
          const perMesh = yield* Effect.forEach(reachable, (row) =>
            store.listDevices(principal.tenantId, row.cmuxId).pipe(Effect.catchAll(dependencyDown("mesh.listDevices"))),
          );
          const visible = yield* visibleDevices(principal, perMesh.flat());
          return new TunnelList({
            items: visible.map((row) => ({
              id: TunnelId_(row.tunnelId),
              deviceId: DeviceId_(row.deviceId),
              meshId: MeshId_(row.meshId),
              name: row.name,
              createdAt: row.createdAt.toISOString(),
            })),
          });
        }),
      ),
    )
    .handle("updateDevice", ({ path, payload }) =>
      withOwnedDevice(path.deviceId, "mesh:join", "write", (caller, device, _proofs, row) =>
        audited(
          "device.update",
          device.value,
          Effect.gen(function* () {
            const tenantId = caller.value.tenantId;
            const store = yield* MeshStore;
            const ownership = yield* OwnershipStore;
            const renamed = yield* store.renameDevice(tenantId, device.value, payload.name).pipe(Effect.catchAll(dependencyDown("mesh.renameDevice")));
            if (!renamed) return yield* Effect.fail(deviceNotFound());
            yield* ownership.setDisplayName(tenantId, "device", device.value, payload.name).pipe(Effect.catchAll(dependencyDown("ownership.setDisplayName")));
            return toDevice({ ...row, name: payload.name });
          }),
        ),
      ),
    )
    .handle("listMeshFirewallRules", ({ path }) =>
      withOwnedMesh(path.meshId, "acl:read", "read", (caller, mesh) =>
        Effect.gen(function* () {
          const tenantId = caller.value.tenantId;
          const acl = yield* (yield* MeshStore).currentAcl(tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
          const items = yield* meshRules(tenantId, mesh.value);
          return new MeshFirewallRuleList({
            meshId: MeshId_(mesh.value),
            aclVersion: Option.match(acl, { onNone: () => 0, onSome: (version) => version.version }),
            items,
          });
        }),
      ),
    )
    .handle("getMeshFirewallRule", ({ path }) =>
      withOwnedMesh(path.meshId, "acl:read", "read", (caller, mesh) =>
        Effect.gen(function* () {
          if (!RULE_ID.test(path.ruleId)) return yield* Effect.fail(ruleNotFound());
          const rules = yield* meshRules(caller.value.tenantId, mesh.value);
          const found = rules.find((rule) => rule.id === path.ruleId);
          if (found === undefined) return yield* Effect.fail(ruleNotFound());
          return found;
        }),
      ),
    )
    .handle("evaluateMeshAcl", ({ path, payload }) =>
      withOwnedMesh(path.meshId, "acl:read", "read", (caller, mesh) =>
        Effect.gen(function* () {
          const tenantId = caller.value.tenantId;
          if (payload.protocol === "icmp" ? payload.port !== undefined : payload.port === undefined) {
            return yield* Effect.fail(new BadRequest({ message: "port is required for tcp and udp, and not allowed for icmp" }));
          }
          const acl = yield* (yield* MeshStore).currentAcl(tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
          const document = Option.match(acl, { onNone: () => EMPTY_ACL, onSome: (version) => version.document });
          const { result, input } = yield* compileFor(tenantId, mesh.value, document, false);
          if (!result.ok) {
            yield* compiled(result);
            return yield* Effect.fail(unavailable());
          }
          if (!input.deviceIds.includes(payload.src)) return yield* Effect.fail(new BadRequest({ message: "src is not a device of this mesh" }));
          const toVm = payload.dst.startsWith("vm_");
          if (!(toVm ? input.vmIds : input.deviceIds).includes(payload.dst)) {
            return yield* Effect.fail(new BadRequest({ message: "dst is not a device or VM of this mesh" }));
          }
          const query = { src: payload.src, dst: payload.dst, protocol: payload.protocol, port: payload.port ?? null };
          const allowed = allowedBy(result.rules, result.overlayRules, query);
          return new MeshAclEvaluation({
            meshId: MeshId_(mesh.value),
            aclVersion: Option.match(acl, { onNone: () => 0, onSome: (version) => version.version }),
            allowed,
            path: toVm ? "firewall" : "overlay",
            ruleIndex: allowed ? firstAllowingRule(input, document.rules, query) : null,
          });
        }),
      ),
    ),
);
