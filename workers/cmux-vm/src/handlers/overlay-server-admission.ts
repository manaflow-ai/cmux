import type { Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { OverlayServer } from "../api/overlay-servers.ts";
import { MeshStore } from "../db/mesh.ts";
import type { OverlayServerRow } from "../db/overlay-servers.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { Conflict, NotFound, QuotaExceeded, unavailable } from "../errors.ts";
import { newDeviceId, parseDeviceId, parseMeshId, type MeshId } from "../lib/ids.ts";
import { MeshConfig } from "../mesh/config.ts";
import { tenantOwnsMesh } from "../proofs/tenant-owns-resource.ts";
import { dependencyDown } from "./common.ts";
import { assertOverlayServerFits } from "./mesh.ts";

export interface ServerBinding { readonly name: string; readonly wgPublicKey: string; readonly installPublicKey: string }
export const toServer = (row: OverlayServerRow) => new OverlayServer({ id: Option.getOrThrow(parseDeviceId(row.deviceId)), meshId: Option.getOrThrow(parseMeshId(row.meshId)), name: row.name, wgPublicKey: row.wgPublicKey, installPublicKey: row.installPublicKey, createdAt: row.createdAt.toISOString(), kind: "server", transport: "overlay" });

/** Called under the mesh writer by both credential enrollment and approved codes. Does not persist. */
export const prepareOverlayServer = <C, M>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, binding: ServerBinding, expectedId?: string) => Effect.gen(function* () {
  if ((yield* tenantOwnsMesh(caller, mesh).pipe(Effect.mapError(() => unavailable()))) === null) return yield* Effect.fail(new NotFound({ message: "Mesh not found" }));
  const store = yield* MeshStore;
  const servers = yield* store.listOverlayServers(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("overlay.list")));
  const existing = servers.find((row) => row.installPublicKey === binding.installPublicKey);
  if (existing !== undefined) {
    if (existing.createdBy === actorRef(caller.value.actor) && existing.wgPublicKey === binding.wgPublicKey && existing.name === binding.name && (expectedId === undefined || expectedId === existing.deviceId)) return { row: existing, existing: true };
    return yield* Effect.fail(new Conflict({ message: "This install already has a different server identity in the mesh; revoke it before enrolling another" }));
  }
  const gateways = yield* store.listDevices(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
  if ([...servers, ...gateways].some((row) => row.wgPublicKey === binding.wgPublicKey)) return yield* Effect.fail(new Conflict({ message: "This WireGuard key already belongs to a mesh identity" }));
  const config = yield* MeshConfig;
  if (servers.length >= config.budgets.overlayServersPerMesh) return yield* Effect.fail(new QuotaExceeded({ message: `This mesh has reached its ${config.budgets.overlayServersPerMesh} provider-free server limit` }));
  const row: OverlayServerRow = { deviceId: expectedId ?? newDeviceId(), meshId: mesh.value, name: binding.name, wgPublicKey: binding.wgPublicKey, installPublicKey: binding.installPublicKey, createdBy: actorRef(caller.value.actor), createdAt: new Date(yield* Clock.currentTimeMillis) };
  yield* assertOverlayServerFits(caller.value.tenantId, row);
  return { row, existing: false };
});
