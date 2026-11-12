import { Clock, Effect } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { OverlayServerRow } from "../db/overlay-servers.ts";
import type { Principal } from "../domain/principal.ts";
import { compileAcl, isAddressRuleKey, type AclDocument, type CompileResult } from "../mesh/acl.ts";
import { MeshConfig } from "../mesh/config.ts";
import { dependencyDown } from "./common.ts";

/** Times `effect` into `into[key]` (milliseconds) when `into` is given, success or failure. */
const timed = <A, E, R>(into: Record<string, string> | undefined, key: string, effect: Effect.Effect<A, E, R>) =>
  into === undefined
    ? effect
    : Effect.flatMap(Clock.currentTimeMillis, (started) =>
        effect.pipe(Effect.ensuring(Effect.flatMap(Clock.currentTimeMillis, (at) => Effect.sync(() => { into[key] = String(at - started); })))));

/**
 * Compiles `document` against the mesh's live devices and VMs. Lenient: names that left the mesh are skipped.
 * `phases` (an attach's mesh_vm_attach line) gets each read's time (read*Ms) and the mesh's size (members, devices).
 * A Worker's clock stands still while code runs, so the compile's own CPU reads as compileMs minus the slowest read.
 */
export const compileMeshPolicy = (tenantId: Principal["tenantId"], meshId: string, document: AclDocument, strict: boolean, additional: ReadonlyArray<OverlayServerRow> = [], phases?: Record<string, string>) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const config = yield* MeshConfig;
    // Five independent reads of one mesh, issued together: one database round trip instead of five
    // (each is a Worker-to-database hop). Writers hold the mesh writer lease, which keeps them consistent; the
    // receiver-policy read takes no lock and compiles twice instead, refusing any difference.
    const [gatewayDevices, servers, members, deviceIpv6, recorded] = yield* Effect.all([
      timed(phases, "readDevicesMs", store.listDevices(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")))),
      timed(phases, "readServersMs", store.listOverlayServers(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("overlay.list")))),
      timed(phases, "readMembersMs", store.listMembers(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listMembers")))),
      timed(phases, "readAddressesMs", store.deviceAddresses(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.deviceAddresses")))),
      timed(phases, "readRulesMs", store.listRules(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listRules")))),
    ], { concurrency: "unbounded" });
    const devices = [...gatewayDevices, ...servers, ...additional];
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
    if (phases !== undefined) {
      phases.members = String(vmIds.length);
      phases.devices = String(deviceIds.length);
    }
    return { result, members, devices };
  });

