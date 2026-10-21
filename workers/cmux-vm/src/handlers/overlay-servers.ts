import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { prepareOverlayServer, toServer } from "./overlay-server-admission.ts";
import { issueOverlayServerCode, redeemOverlayServerCode } from "./overlay-server-codes.ts";
import { CmuxVmApi } from "../api.ts";
import { OverlayServerList, OverlayServerPolicy } from "../api/overlay-servers.ts";
import type { SignedDeviceRequest } from "../api/mesh.ts";
import { MeshStore } from "../db/mesh.ts";
import type { OverlayServerRow } from "../db/overlay-servers.ts";
import { CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { Conflict, Forbidden, NotFound, unavailable } from "../errors.ts";
import { parseDeviceId, type DeviceId } from "../lib/ids.ts";
import { MeshConfig } from "../mesh/config.ts";
import { actorOf, ownerStillValid } from "../mesh/owner.ts";
import { deviceHoldsKey } from "../proofs/device-holds-key.ts";
import { callerActsOnOverlayServer, type CallerActsOnOverlayServer } from "../proofs/overlay-server.ts";
import { audited, dependencyDown, rateLimit } from "./common.ts";
import { overlayPolicyOf, withMeshCaller, withMeshWriter, withOwnedMesh } from "./mesh.ts";

const missing = () => new NotFound({ message: "Overlay server not found" });
const signatureRefused = (reason: "invalid" | "stale" | "replayed") => reason === "replayed"
  ? new Conflict({ message: "This signed request was already used; sign a fresh request" })
  : new Forbidden({ message: reason === "stale" ? "The request is stale; sign it again" : "The install signature does not verify" });

const withOwnedServer = <A, E, R>(rawId: string, rate: "read" | "write", k: <C, D>(caller: Named<C, Principal>, device: Named<D, DeviceId>, proof: CallerActsOnOverlayServer<C, D>) => Effect.Effect<A, E, R>) =>
  withMeshCaller("mesh:join", rate, (caller) => Effect.gen(function* () {
    const parsed = parseDeviceId(rawId);
    if (Option.isNone(parsed)) return yield* Effect.fail(missing());
    return yield* name(parsed.value, (device) => Effect.gen(function* () {
      const proof = yield* callerActsOnOverlayServer(caller, device).pipe(Effect.mapError(() => unavailable()));
      if (proof === null) return yield* Effect.fail(missing());
      return yield* k(caller, device, proof);
    }));
  }));

const readPolicy = (principal: Principal, row: OverlayServerRow) => overlayPolicyOf(principal.tenantId, row.deviceId, row)
  .pipe(Effect.map((policy) => new OverlayServerPolicy({ ...policy, tenantId: principal.tenantId })));

/** Both credential and install-signed revocation use this mutation and audit path. */
const revoke = <C, D>(caller: Named<C, Principal>, device: Named<D, DeviceId>, proof: CallerActsOnOverlayServer<C, D>) =>
  audited("overlay_server.revoke", device.value, withMeshWriter(caller.value.tenantId, proof.row.meshId, Effect.gen(function* () {
    const current = yield* callerActsOnOverlayServer(caller, device).pipe(Effect.mapError(() => unavailable()));
    if (current === null) return yield* Effect.fail(missing());
    yield* (yield* MeshStore).revokeOverlayServer(caller.value.tenantId, device.value, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.catchAll(dependencyDown("overlay.revoke")));
  })));

/** No session or reusable credential leaves this handler: the install signature acts only on its own identity. */
const withSignedServer = <A, E, R>(rawId: string, payload: SignedDeviceRequest, purpose: "overlay-server-policy" | "revoke-overlay-server", rate: "read" | "write", k: <C, D>(caller: Named<C, Principal>, device: Named<D, DeviceId>, proof: CallerActsOnOverlayServer<C, D>) => Effect.Effect<A, E, R>) => Effect.gen(function* () {
  const config = yield* MeshConfig;
  if (!config.experiment) return yield* Effect.fail(missing());
  const parsed = parseDeviceId(rawId);
  if (Option.isNone(parsed)) return yield* Effect.fail(missing());
  const found = yield* (yield* MeshStore).findOverlayServerForSignature(parsed.value).pipe(Effect.catchAll(dependencyDown("overlay.findForSignature")));
  if (Option.isNone(found) || !config.enabledFor(found.value.tenantId)) return yield* Effect.fail(missing());
  const row = found.value;
  const actor = actorOf(row.createdBy);
  if (Option.isNone(actor)) return yield* Effect.fail(missing());
  const principal: Principal = { tenantId: row.tenantId, actor: actor.value, scopes: new Set<Scope>(["mesh:join", "mesh:read"]), resourceAllowlist: new Set([row.deviceId]), credentialExpiresAt: null, actingDevice: row.deviceId };
  return yield* name(principal, parsed.value, (caller, device) => Effect.gen(function* () {
    const held = yield* deviceHoldsKey(caller, device, { purpose, wgPublicKey: "", installPublicKey: row.installPublicKey, name: "", signedAt: payload.signedAt, nonce: payload.nonce }, payload.signature, row.installPublicKey).pipe(Effect.catchAll(dependencyDown("mesh.claimSignedRequest")));
    if (held._tag === "invalid") return yield* Effect.fail(missing());
    if (!(yield* ownerStillValid(principal.tenantId, principal.actor, true))) return yield* Effect.fail(missing());
    if (held._tag !== "held") return yield* Effect.fail(signatureRefused(held._tag));
    yield* rateLimit(principal, rate);
    const access = yield* callerActsOnOverlayServer(caller, device).pipe(Effect.mapError(() => unavailable()));
    if (access === null) return yield* Effect.fail(missing());
    return yield* k(caller, device, access);
  })).pipe(Effect.provideService(CurrentPrincipal, principal));
});

export const overlayServerHandlers = HttpApiBuilder.group(CmuxVmApi, "overlayServers", (handlers) => handlers
  .handle("createOverlayServerCode", ({ path, payload }) => issueOverlayServerCode(path.meshId, payload))
  .handle("enrollOverlayServer", ({ path, payload }) => withOwnedMesh(path.meshId, "mesh:join", "write", (caller, mesh) =>
    audited("overlay_server.create", mesh.value, withMeshWriter(caller.value.tenantId, mesh.value, Effect.gen(function* () {
      const held = yield* deviceHoldsKey(caller, mesh, { purpose: "enroll-overlay-server", ...payload }, payload.signature, null).pipe(Effect.catchAll(dependencyDown("mesh.claimSignedRequest")));
      if (held._tag !== "held") return yield* Effect.fail(signatureRefused(held._tag));
      const { row, existing } = yield* prepareOverlayServer(caller, mesh, payload);
      if (!existing) {
        const recorded = yield* (yield* MeshStore).recordOverlayServer(caller.value.tenantId, row).pipe(Effect.catchAll(dependencyDown("overlay.record")));
        if (!recorded) return yield* Effect.fail(new Conflict({ message: "This mesh identity was enrolled concurrently; retry with a fresh signature" }));
      }
      return toServer(row);
    })), (row) => row.id)))
  .handle("listOverlayServers", ({ path }) => withOwnedMesh(path.meshId, "mesh:read", "read", (caller, mesh) => Effect.gen(function* () {
    const rows = yield* (yield* MeshStore).listOverlayServers(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("overlay.list")));
    const visible = [];
    for (const row of rows) {
      const id = parseDeviceId(row.deviceId); if (Option.isNone(id)) continue;
      const allowed = yield* name(id.value, (device) => callerActsOnOverlayServer(caller, device).pipe(Effect.map((proof) => proof !== null))).pipe(Effect.mapError(() => unavailable()));
      if (allowed) visible.push(toServer(row));
    }
    return new OverlayServerList({ items: visible });
  })))
  .handle("getOverlayServer", ({ path }) => withOwnedServer(path.deviceId, "read", (_caller, _device, proof) => Effect.succeed(toServer(proof.row))))
  .handle("getOverlayServerPolicy", ({ path }) => withOwnedServer(path.deviceId, "read", (caller, _device, proof) => readPolicy(caller.value, proof.row)))
  .handle("revokeOverlayServer", ({ path }) => withOwnedServer(path.deviceId, "write", revoke)));

export const overlayServerDeviceHandlers = HttpApiBuilder.group(CmuxVmApi, "overlayServerDevice", (handlers) => handlers
  .handle("codeEnrollOverlayServer", ({ path, payload }) => redeemOverlayServerCode(path.meshId, payload))
  .handle("signedOverlayServerPolicy", ({ path, payload }) => withSignedServer(path.deviceId, payload, "overlay-server-policy", "read", (caller, _device, proof) => readPolicy(caller.value, proof.row)))
  .handle("signedRevokeOverlayServer", ({ path, payload }) => withSignedServer(path.deviceId, payload, "revoke-overlay-server", "write", revoke)));
