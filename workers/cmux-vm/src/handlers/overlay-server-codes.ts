import { name } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { OverlayServerBinding, OverlayServerCode, type CodeEnrollOverlayServerRequest } from "../api/overlay-servers.ts";
import { MeshStore } from "../db/mesh.ts";
import { actorRef, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { Conflict, Forbidden, NotFound, QuotaExceeded } from "../errors.ts";
import { parseDeviceId, parseMeshId, randomIdBody } from "../lib/ids.ts";
import { ENROLLMENT_CODE_TTL_MS, MeshConfig } from "../mesh/config.ts";
import { actorOf, ownerStillValid } from "../mesh/owner.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import { deviceHoldsKey } from "../proofs/device-holds-key.ts";
import { audited, dependencyDown, rateLimit } from "./common.ts";
import { withMeshWriter, withOwnedMesh } from "./mesh.ts";
import { prepareOverlayServer, toServer } from "./overlay-server-admission.ts";

const missing = () => new NotFound({ message: "Server enrollment code not found" });
const now = Clock.currentTimeMillis.pipe(Effect.map((ms) => new Date(ms)));

export const issueOverlayServerCode = (meshId: string, binding: OverlayServerBinding) => withOwnedMesh(meshId, "mesh:join", "write", (caller, mesh) =>
  audited("overlay_server.code.create", mesh.value, withMeshWriter(caller.value.tenantId, mesh.value, Effect.gen(function* () {
    if (!(yield* ownerStillValid(caller.value.tenantId, caller.value.actor, true))) return yield* Effect.fail(missing());
    const store = yield* MeshStore;
    const at = yield* now;
    const recent = yield* store.recentOverlayServerCodes(caller.value.tenantId, mesh.value, new Date(at.getTime() - 3_600_000)).pipe(Effect.catchAll(dependencyDown("serverCode.recent")));
    if (recent.length >= (yield* MeshConfig).budgets.overlayServerCodesPerHour) return yield* Effect.fail(new QuotaExceeded({ message: "This mesh has reached its hourly server enrollment code limit" }));
    const pending = recent.find((c) => c.usedAt === null && c.burnedAt === null && c.expiresAt > at && c.createdBy === actorRef(caller.value.actor) && c.name === binding.name && c.wgPublicKey === binding.wgPublicKey && c.installPublicKey === binding.installPublicKey);
    const prepared = yield* prepareOverlayServer(caller, mesh, binding, pending?.deviceId);
    const code = `msc_${randomIdBody()}`;
    const expiresAt = new Date(at.getTime() + ENROLLMENT_CODE_TTL_MS);
    yield* store.insertOverlayServerCode({ ...prepared.row, tenantId: caller.value.tenantId, createdAt: at, codeSha256: yield* sha256Hex(code), expiresAt, usedAt: null, burnedAt: null }).pipe(Effect.catchAll(dependencyDown("serverCode.insert")));
    return new OverlayServerCode({ code, deviceId: Option.getOrThrow(parseDeviceId(prepared.row.deviceId)), meshId: mesh.value, tenantId: caller.value.tenantId, expiresAt: expiresAt.toISOString(), binding });
  }))));

export const redeemOverlayServerCode = (meshId: string, payload: CodeEnrollOverlayServerRequest) => Effect.gen(function* () {
  const config = yield* MeshConfig;
  if (!config.experiment) return yield* Effect.fail(missing());
  const store = yield* MeshStore;
  const hash = yield* sha256Hex(payload.code);
  const found = yield* store.findOverlayServerCode(hash).pipe(Effect.catchAll(dependencyDown("serverCode.find")));
  if (Option.isNone(found) || !config.enabledFor(found.value.tenantId)) return yield* Effect.fail(missing());
  const code = found.value;
  const refuse = <E>(error: E) => now.pipe(Effect.flatMap((at) => store.burnOverlayServerCode(hash, at))).pipe(Effect.catchAll(dependencyDown("serverCode.burn")), Effect.zipRight(Effect.fail(error)));
  const parsed = parseMeshId(meshId);
  if (Option.isNone(parsed) || parsed.value !== code.meshId || code.burnedAt !== null || code.expiresAt <= (yield* now)) return yield* refuse(missing());
  if (payload.name !== code.name || payload.wgPublicKey !== code.wgPublicKey || payload.installPublicKey !== code.installPublicKey) return yield* refuse(missing());
  const actor = actorOf(code.createdBy);
  if (Option.isNone(actor)) return yield* refuse(missing());
  const principal: Principal = { tenantId: code.tenantId, actor: actor.value, scopes: new Set<Scope>(["mesh:join", "mesh:read"]), resourceAllowlist: new Set([code.meshId]), credentialExpiresAt: code.expiresAt, actingDevice: code.deviceId };
  return yield* name(principal, parsed.value, (caller, mesh) => audited("overlay_server.create", code.deviceId, withMeshWriter(code.tenantId, mesh.value, Effect.gen(function* () {
    if (!(yield* ownerStillValid(code.tenantId, principal.actor, true))) return yield* refuse(missing());
    yield* rateLimit(principal, "write");
    const held = yield* deviceHoldsKey(caller, mesh, { ...payload, purpose: "enroll-overlay-server", name: `${payload.code}:${payload.name}` }, payload.signature, code.installPublicKey).pipe(Effect.catchAll(dependencyDown("mesh.claimSignedRequest")));
    if (held._tag !== "held") return yield* refuse(held._tag === "replayed" ? new Conflict({ message: "This signed request was already used; sign a fresh request" }) : new Forbidden({ message: "The install signature is invalid or stale; sign a fresh request" }));
    // Used invitations are receipts only; never prepare a replacement for a revoked server.
    if (code.usedAt !== null && Option.isNone(yield* store.getOverlayServer(code.tenantId, code.deviceId).pipe(Effect.catchAll(dependencyDown("overlay.get"))))) return yield* Effect.fail(missing());
    yield* prepareOverlayServer(caller, mesh, code, code.deviceId);
    const committed = yield* store.redeemOverlayServerCode(code.tenantId, hash, mesh.value, yield* now).pipe(Effect.catchAll(dependencyDown("serverCode.redeem")));
    if (!committed) return yield* Effect.fail(new Conflict({ message: "The reserved identity could not be enrolled; retry with a fresh signature" }));
    const row = yield* store.getOverlayServer(code.tenantId, code.deviceId).pipe(Effect.catchAll(dependencyDown("overlay.get")));
    if (Option.isNone(row)) return yield* Effect.fail(missing());
    return toServer(row.value);
  })))).pipe(Effect.provideService(CurrentPrincipal, principal));
});
