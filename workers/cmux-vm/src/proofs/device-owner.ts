/**
 * Trusted module: the only place a CallerActsOnDevice proof is minted (mesh
 * M2, cx-0op.4).
 *
 * Inside one tenant, caller C may act on a device (or on that device's tunnel)
 * only when C enrolled it, that is the device row's `created_by` is C's actor
 * (the Stack user id of a session, or the API key id), or when C is a tenant
 * admin: an API key issued with the `admin` scope, or a session of a Stack team
 * admin. Every other caller of the tenant sees the device as absent (404), so a
 * device id leaks nothing to a principal that cannot act on it.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { IdentityUnavailable } from "../auth/credentials.ts";
import { TeamAdmin } from "../auth/team-admin.ts";
import type { MeshDeviceRow } from "../db/mesh.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import type { DeviceId, TunnelId } from "../lib/ids.ts";
import type { TenantOwnsResource } from "./tenant-owns-resource.ts";

const CallerActsOnDeviceProof = defineProof("CallerActsOnDevice");

/** Caller `C` enrolled the device `R` names (a device or its tunnel), or `C` is a tenant admin. */
export interface CallerActsOnDevice<C, R> extends Proof<"CallerActsOnDevice", [C, R]> {
  readonly as: "owner" | "admin";
}

/** A tenant admin: an API key with the `admin` scope, or a session of a Stack team admin. */
export const isTenantAdmin = (principal: Principal): Effect.Effect<boolean, IdentityUnavailable, TeamAdmin> => {
  const actor = principal.actor;
  if (actor.kind === "api_key") return Effect.succeed(principal.scopes.has("admin"));
  return Effect.flatMap(TeamAdmin, (admins) => admins.isAdmin(principal.tenantId, actor.userId));
};

/** Whether `principal` enrolled the device in `row`. */
export const enrolledBy = (principal: Principal, row: MeshDeviceRow): boolean => row.createdBy === actorRef(principal.actor);

const decide = <C, R>(caller: Named<C, Principal>, resource: Named<R, unknown>, row: MeshDeviceRow) =>
  Effect.gen(function* () {
    if (enrolledBy(caller.value, row)) return Object.freeze({ ...CallerActsOnDeviceProof.prove(caller, resource), as: "owner" as const });
    if (yield* isTenantAdmin(caller.value)) return Object.freeze({ ...CallerActsOnDeviceProof.prove(caller, resource), as: "admin" as const });
    return null;
  });

/** `row` must be the device `device` names, read for the caller's tenant (the ownership proof is that tenant's). */
export const callerActsOnDevice = <C, D>(
  caller: Named<C, Principal>,
  device: Named<D, DeviceId>,
  _owns: TenantOwnsResource<C, D>,
  row: MeshDeviceRow,
): Effect.Effect<CallerActsOnDevice<C, D> | null, IdentityUnavailable, TeamAdmin> =>
  row.deviceId === device.value ? decide(caller, device, row) : Effect.succeed(null);

/** `row` must be the device whose tunnel `tunnel` names. */
export const callerActsOnTunnel = <C, T>(
  caller: Named<C, Principal>,
  tunnel: Named<T, TunnelId>,
  _owns: TenantOwnsResource<C, T>,
  row: MeshDeviceRow,
): Effect.Effect<CallerActsOnDevice<C, T> | null, IdentityUnavailable, TeamAdmin> =>
  row.tunnelId === tunnel.value ? decide(caller, tunnel, row) : Effect.succeed(null);
