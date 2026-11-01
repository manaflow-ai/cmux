import { Effect } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { OverlayServerRow } from "../db/overlay-servers.ts";
import type { Principal } from "../domain/principal.ts";
import { compileAcl, isAddressRuleKey, type AclDocument, type CompileResult } from "../mesh/acl.ts";
import { MeshConfig } from "../mesh/config.ts";
import { dependencyDown } from "./common.ts";

/** Compiles `document` against the mesh's live devices and VMs. Lenient: names that left the mesh are skipped. */
export const compileMeshPolicy = (tenantId: Principal["tenantId"], meshId: string, document: AclDocument, strict: boolean, additional: ReadonlyArray<OverlayServerRow> = []) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const config = yield* MeshConfig;
    const gatewayDevices = yield* store.listDevices(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
    const servers = yield* store.listOverlayServers(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("overlay.list")));
    const devices = [...gatewayDevices, ...servers, ...additional];
    const members = yield* store.listMembers(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listMembers")));
    const deviceIpv6 = yield* store.deviceAddresses(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.deviceAddresses")));
    const recorded = yield* store.listRules(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listRules")));
    const existingAddressKeys = new Set(recorded.filter((rule) => isAddressRuleKey(rule.key)).map((rule) => rule.key));
    const deviceIds = devices.map((device) => device.deviceId);
    const vmIds = members.map((member) => member.vmId);
    const known = new Set([...deviceIds, ...vmIds]);
    const effective: AclDocument = strict
      ? document
      : {
          rules: document.rules
            .map((rule) => ({
              src: rule.src.filter((entry) => entry.endsWith(":*") || known.has(entry)),
              dst: rule.dst.filter((entry) => entry.endsWith(":*") || known.has(entry)),
              allow: rule.allow,
            }))
            .filter((rule) => rule.src.length > 0 && rule.dst.length > 0),
        };
    const result: CompileResult = compileAcl({
      document: effective,
      deviceIds,
      sourceDeviceIds: gatewayDevices.map((device) => device.deviceId),
      vmIds,
      deviceIpv6,
      existingAddressKeys,
      rulesPerResource: config.budgets.rulesPerResource,
      rulesPerMesh: config.budgets.rulesPerMesh,
      overlayRulesPerMesh: config.budgets.overlayRulesPerMesh,
      overlayRulesPerDevice: config.budgets.overlayRulesPerDevice,
    });
    return { result, members, devices };
  });

