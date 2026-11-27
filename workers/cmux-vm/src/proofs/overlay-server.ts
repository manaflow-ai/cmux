import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { MeshStore } from "../db/mesh.ts";
import type { OverlayServerRow } from "../db/overlay-servers.ts";
import { OwnershipStore } from "../db/stores.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import type { DeviceId } from "../lib/ids.ts";
import { isTenantAdmin } from "./device-owner.ts";

const Access = defineProof("CallerActsOnOverlayServer");
/** Distinct from provider-resource proofs: it cannot authorize a provider call. */
export interface CallerActsOnOverlayServer<C, D> extends Proof<"CallerActsOnOverlayServer", [C, D]> {
  readonly row: OverlayServerRow;
}

export const callerActsOnOverlayServer = <C, D>(caller: Named<C, Principal>, device: Named<D, DeviceId>) => Effect.gen(function* () {
  const p = caller.value;
  if (p.actor.kind === "service" || (p.resourceAllowlist !== null && !p.resourceAllowlist.has(device.value))) return null;
  const found = yield* (yield* MeshStore).getOverlayServer(p.tenantId, device.value);
  if (Option.isNone(found)) return null;
  const mesh = yield* (yield* OwnershipStore).find(p.tenantId, "mesh", found.value.meshId);
  if (Option.isNone(mesh)) return null;
  if (found.value.createdBy !== actorRef(p.actor) && !(yield* isTenantAdmin(p))) return null;
  const proof: CallerActsOnOverlayServer<C, D> = Object.freeze({ ...Access.prove(caller, device), row: found.value });
  return proof;
});
