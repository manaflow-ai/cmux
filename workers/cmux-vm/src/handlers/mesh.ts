/**
 * Mesh experiment endpoints (cx-0op, workers/cmux-vm/mesh/M1-PLAN.md).
 *
 * Order on every route: the experiment gate (404 for a team without the
 * experiment, before anything else is read), then the scope (403), the rate
 * limit (429), then ownership through the caller's tenant (another tenant's id
 * is 404). The ACL is the only writer of provider firewall rules for a mesh:
 * rules are created from two SameMesh proofs and deleted only with an
 * OwnedMeshRule proof, new rules before old ones (DESIGN.md 4.3).
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { Acl, AclApplied, Device, DeviceEnrollment, DeviceList, EnrollmentCode, Mesh, MeshList, MeshMember, PeerMap, TunnelConfig } from "../api/mesh.ts";
import { TeamMembership } from "../auth/credentials.ts";
import { TeamAdmin } from "../auth/team-admin.ts";
import { MeshStore, type MeshDeviceRow } from "../db/mesh.ts";
import { OwnershipStore } from "../db/stores.ts";
import { actorRef, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import {
  BadRequest,
  Conflict,
  Forbidden,
  missingScope,
  NotFound,
  PaymentRequired,
  QuotaExceeded,
  ServiceUnavailable,
  unavailable,
  vmNotFound,
} from "../errors.ts";
import {
  ApiKeyId,
  UserId,
  randomIdBody,
  newDeviceId,
  newMeshId,
  newTunnelId,
  parseDeviceId,
  parseMeshId,
  parseTunnelId,
  parseVmId,
  type DeviceId,
  type MeshId,
  type TunnelId,
  type VmId,
} from "../lib/ids.ts";
import type { RateClass } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import { compileAcl, peersOf, planApply, type AclDocument, type CompileResult, type DesiredRule } from "../mesh/acl.ts";
import { ENROLLMENT_CODE_TTL_MS, MESH_MTU, MESH_PERSISTENT_KEEPALIVE_SECONDS, MESH_SLOTS, MeshConfig, slotCidr } from "../mesh/config.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import { deviceHoldsKey } from "../proofs/device-holds-key.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantMayCreateDevice, tenantMayCreateMesh } from "../proofs/mesh-may-create.ts";
import { ownedMeshRules, sameMeshDevice, sameMeshVm } from "../proofs/same-mesh.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import { callerActsOnDevice, callerActsOnTunnel, enrolledBy, isTenantAdmin, type CallerActsOnDevice } from "../proofs/device-owner.ts";
import { tenantOwnsDevice, tenantOwnsMesh, tenantOwnsTunnel, tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamMesh, type TunnelInfo } from "../upstream/mesh.ts";
import { audited, dependencyDown, rateLimit } from "./common.ts";

const experimentOff = () => new NotFound({ message: "Not found" });
const meshNotFound = () => new NotFound({ message: "Mesh not found" });
const deviceNotFound = () => new NotFound({ message: "Device not found" });
const tunnelNotFound = () => new NotFound({ message: "Tunnel not found" });

/** A structured Worker log line naming only public ids. */
const logEvent = (event: string, fields: Record<string, string>) => Effect.sync(() => console.error(JSON.stringify({ event, ...fields })));

const now = Effect.map(Clock.currentTimeMillis, (ms) => new Date(ms));

/** The experiment gate: a team without the experiment sees no mesh route at all. */
const gate = Effect.gen(function* () {
  const principal = yield* CurrentPrincipal;
  const config = yield* MeshConfig;
  if (!config.enabledFor(principal.tenantId)) return yield* Effect.fail(experimentOff());
  return principal;
});

const withMeshCaller = <const S extends Scope, A, E, R>(
  scope: S,
  rateClass: RateClass,
  k: <C>(caller: Named<C, Principal>, granted: KeyHasScope<C, S>) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* gate;
    return yield* name(principal, (caller) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        yield* rateLimit(principal, rateClass);
        return yield* k(caller, granted);
      }),
    );
  });

const withOwnedMesh = <const S extends Scope, A, E, R>(
  rawId: string,
  scope: S,
  rateClass: RateClass,
  k: <C, M>(
    caller: Named<C, Principal>,
    mesh: Named<M, MeshId>,
    proofs: { readonly owns: TenantOwnsResource<C, M>; readonly scope: KeyHasScope<C, S> },
  ) => Effect.Effect<A, E, R>,
) =>
  withMeshCaller(scope, rateClass, (caller, granted) =>
    Effect.gen(function* () {
      const parsed = parseMeshId(rawId);
      if (Option.isNone(parsed)) return yield* Effect.fail(meshNotFound());
      return yield* name(parsed.value, (mesh) =>
        Effect.gen(function* () {
          const owns = yield* tenantOwnsMesh(caller, mesh).pipe(Effect.catchAll(dependencyDown("ownership.find")));
          if (owns === null) return yield* Effect.fail(meshNotFound());
          return yield* k(caller, mesh, { owns, scope: granted });
        }),
      );
    }),
  );

const withOwnedDevice = <const S extends Scope, A, E, R>(
  rawId: string,
  scope: S,
  rateClass: RateClass,
  k: <C, D>(
    caller: Named<C, Principal>,
    device: Named<D, DeviceId>,
    proofs: { readonly owns: TenantOwnsResource<C, D>; readonly scope: KeyHasScope<C, S>; readonly acts: CallerActsOnDevice<C, D> },
    row: MeshDeviceRow,
  ) => Effect.Effect<A, E, R>,
) =>
  withMeshCaller(scope, rateClass, (caller, granted) =>
    Effect.gen(function* () {
      const parsed = parseDeviceId(rawId);
      if (Option.isNone(parsed)) return yield* Effect.fail(deviceNotFound());
      const store = yield* MeshStore;
      return yield* name(parsed.value, (device) =>
        Effect.gen(function* () {
          const owns = yield* tenantOwnsDevice(caller, device).pipe(Effect.catchAll(dependencyDown("ownership.find")));
          if (owns === null) return yield* Effect.fail(deviceNotFound());
          const row = yield* store.getDevice(caller.value.tenantId, device.value).pipe(Effect.catchAll(dependencyDown("mesh.getDevice")));
          if (Option.isNone(row)) return yield* Effect.fail(deviceNotFound());
          // Inside the tenant, only the enrolling principal or a tenant admin sees the device (cx-0op.4).
          const acts = yield* callerActsOnDevice(caller, device, owns, row.value).pipe(Effect.mapError(() => unavailable()));
          if (acts === null) return yield* Effect.fail(deviceNotFound());
          return yield* k(caller, device, { owns, scope: granted, acts }, row.value);
        }),
      );
    }),
  );

/** A session must belong to a team admin; an API key is trusted with the scope it was issued (by an admin). */
const requireAdmin = (principal: Principal, scope: Scope) =>
  Effect.gen(function* () {
    if (principal.actor.kind !== "session") return;
    const admin = yield* (yield* TeamAdmin).isAdmin(principal.tenantId, principal.actor.userId).pipe(Effect.mapError(() => unavailable()));
    if (!admin) return yield* Effect.fail(new Forbidden({ message: "Only a team admin can change the mesh or its ACL", missingScope: scope }));
  });

const toMesh = (id: string, displayName: string | null, cidr: string, createdAt: Date) =>
  new Mesh({ id: MeshId_(id), displayName, ipv4Cidr: cidr, createdAt: createdAt.toISOString() });

// Rows hold ids this service minted and validated on write; decode them back to their brands.
const MeshId_ = (id: string): MeshId => Option.getOrThrow(parseMeshId(id));
const DeviceId_ = (id: string): DeviceId => Option.getOrThrow(parseDeviceId(id));
const TunnelId_ = (id: string): TunnelId => Option.getOrThrow(parseTunnelId(id));
const VmId_ = (id: string): VmId => Option.getOrThrow(parseVmId(id));

const toDevice = (row: MeshDeviceRow) =>
  new Device({
    id: DeviceId_(row.deviceId),
    meshId: MeshId_(row.meshId),
    name: row.name,
    wgPublicKey: row.wgPublicKey,
    installPublicKey: row.installPublicKey,
    tunnelId: TunnelId_(row.tunnelId),
    createdAt: row.createdAt.toISOString(),
  });

const toTunnel = (row: MeshDeviceRow, info: TunnelInfo) =>
  new TunnelConfig({
    id: TunnelId_(row.tunnelId),
    meshId: MeshId_(row.meshId),
    deviceId: DeviceId_(row.deviceId),
    endpointHost: info.endpointHost,
    endpointPort: info.endpointPort,
    serverPublicKey: info.serverPublicKey,
    interfaceAddress: info.interfaceAddress,
    meshAddress: info.meshAddress,
    allowedIps: [...info.allowedIps],
    mtu: MESH_MTU,
    persistentKeepaliveSeconds: MESH_PERSISTENT_KEEPALIVE_SECONDS,
  });

const EMPTY_ACL: AclDocument = { rules: [] };

/** Compiles `document` against the mesh's live devices and VMs. Lenient: names that left the mesh are skipped. */
const compileFor = (tenantId: Principal["tenantId"], meshId: string, document: AclDocument, strict: boolean) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const config = yield* MeshConfig;
    const devices = yield* store.listDevices(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
    const members = yield* store.listMembers(tenantId, meshId).pipe(Effect.catchAll(dependencyDown("mesh.listMembers")));
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
      vmIds,
      rulesPerResource: config.budgets.rulesPerResource,
      rulesPerMesh: config.budgets.rulesPerMesh,
    });
    return { result, members };
  });

const compiled = (result: CompileResult) =>
  Effect.gen(function* () {
    if (result.ok) return result.rules;
    if (result.reason === "invalid") return yield* Effect.fail(new BadRequest({ message: result.message }));
    return yield* Effect.fail(
      new QuotaExceeded({
        message: result.message,
        budget: result.reason === "perResource" ? "firewallRule.perResource" : "firewallRule.perMesh",
      }),
    );
  });

const ruleCreateError = (error: { readonly status: number | null }) =>
  error.status === 409
    ? new QuotaExceeded({ message: "The platform's firewall rule limit is reached; try again later", retryAfterSeconds: 300, budget: "firewallRule.account" })
    : error.status === 404
      ? new Conflict({ message: "A device or VM left the mesh during the change; apply again" })
      : unavailable();

/**
 * Makes the mesh's provider rules equal `desired`: creates every missing rule
 * (8 at a time), and only when all of them exist deletes the surplus, so
 * traffic both the old and the new policy allow never stops. A failed create
 * stops before any delete.
 */
const reconcile = <C, M>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, ownsMesh: TenantOwnsResource<C, M>, desired: ReadonlyArray<DesiredRule>) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const upstream = yield* UpstreamMesh;
    const tenantId = caller.value.tenantId;
    const current = yield* ownedMeshRules(caller, mesh, ownsMesh).pipe(Effect.catchAll(dependencyDown("mesh.listRules")));
    const plan = planApply(
      current.map((proof) => ({ key: proof.rule.key, proof })),
      desired,
    );
    yield* Effect.forEach(
      plan.create,
      (rule) =>
        Effect.gen(function* () {
          const device = parseDeviceId(rule.deviceId);
          const vm = parseVmId(rule.vmId);
          if (Option.isNone(device) || Option.isNone(vm)) return yield* Effect.fail(unavailable());
          return yield* name(device.value, vm.value, (source, destination) =>
            Effect.gen(function* () {
              const sourceProof = yield* sameMeshDevice(caller, mesh, ownsMesh, source).pipe(Effect.catchAll(dependencyDown("mesh.sameMesh")));
              const destinationProof = yield* sameMeshVm(caller, mesh, ownsMesh, destination).pipe(Effect.catchAll(dependencyDown("mesh.sameMesh")));
              if (sourceProof === null || destinationProof === null) {
                return yield* Effect.fail(new Conflict({ message: "A device or VM left the mesh during the change; apply again" }));
              }
              const created = yield* upstream
                .createRule(mesh, source, destination, { source: sourceProof, destination: destinationProof }, { protocol: rule.protocol, port: rule.port })
                .pipe(Effect.mapError(ruleCreateError));
              const at = yield* now;
              yield* store
                .recordRule(tenantId, {
                  meshId: mesh.value,
                  key: rule.key,
                  upstreamRuleId: created.upstreamRuleId,
                  deviceId: rule.deviceId,
                  vmId: rule.vmId,
                  protocol: rule.protocol,
                  port: rule.port,
                  createdAt: at,
                })
                .pipe(
                  // Unrecorded, the rule could never be deleted by the ACL: it is logged by mesh id for the operator.
                  Effect.tapError(() => logEvent("mesh_rule_record_failed", { meshId: mesh.value, ruleKey: rule.key })),
                  Effect.catchAll(dependencyDown("mesh.recordRule")),
                );
            }),
          );
        }),
      { concurrency: 8, discard: true },
    );
    yield* Effect.forEach(
      plan.remove,
      ({ proof }) =>
        Effect.gen(function* () {
          yield* upstream.deleteRule(proof).pipe(
            // Already gone upstream (it named a tunnel or VM that was deleted): finish here.
            Effect.catchIf((error) => error.status === 404, () => Effect.void),
            Effect.mapError(() => unavailable()),
          );
          yield* store.markRuleDeleted(tenantId, mesh.value, proof.rule.key, yield* now).pipe(Effect.catchAll(dependencyDown("mesh.markRuleDeleted")));
        }),
      { concurrency: 8, discard: true },
    );
    return { created: plan.create.length, deleted: plan.remove.length, ruleCount: desired.length };
  });

/** Re-applies the mesh's current ACL after its devices or VMs changed. */
const reconcileCurrent = <C, M>(caller: Named<C, Principal>, mesh: Named<M, MeshId>, ownsMesh: TenantOwnsResource<C, M>) =>
  Effect.gen(function* () {
    const store = yield* MeshStore;
    const acl = yield* store.currentAcl(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
    const document = Option.match(acl, { onNone: () => EMPTY_ACL, onSome: (row) => row.document });
    const { result } = yield* compileFor(caller.value.tenantId, mesh.value, document, false);
    const desired = yield* compiled(result);
    return yield* reconcile(caller, mesh, ownsMesh, desired);
  });

/** Billing (402) then the budget (429); runs `k` with the proof and releases the reservation afterwards. */
const withSlot = <C, K extends "mesh" | "device", A, E, R, E2, R2>(
  decision: Effect.Effect<
    { readonly _tag: "granted"; readonly proof: TenantMayCreate<C, K> } | { readonly _tag: "not_entitled" } | { readonly _tag: "over_budget"; readonly limit: number },
    E2,
    R2
  >,
  tenantId: Principal["tenantId"],
  budget: "mesh.perTenant" | "device.perMesh",
  k: (proof: TenantMayCreate<C, K>) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const decided = yield* decision.pipe(Effect.mapError(() => unavailable()));
    if (decided._tag === "not_entitled") return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include meshes" }));
    if (decided._tag === "over_budget") {
      return yield* Effect.fail(
        new QuotaExceeded({
          message:
            budget === "mesh.perTenant"
              ? `This team already has its limit of ${decided.limit} mesh${decided.limit === 1 ? "" : "es"}`
              : `This mesh already has its limit of ${decided.limit} devices`,
          budget,
        }),
      );
    }
    const limits = yield* TenantLimits;
    return yield* k(decided.proof).pipe(Effect.ensuring(limits.release(tenantId, decided.proof.reservationId)));
  });

/** A refused install-key signature: stale or forged is 403, a replay 409. */
const signatureRefused = (reason: "stale" | "invalid" | "replayed") =>
  reason === "replayed"
    ? new Conflict({ message: "This signed request was already used; sign a new one" })
    : new Forbidden({
        message: reason === "stale" ? "The request's signedAt is more than 120 s from the server's clock; sign it again" : "The install-key signature does not verify",
      });

interface EnrollPayload {
  readonly name: string;
  readonly wgPublicKey: string;
  readonly installPublicKey: string;
  readonly signedAt: number;
  readonly nonce: string;
  readonly signature: string;
}

/**
 * Enrolls a device into `mesh` for `caller`, who becomes its owner: the
 * install key must have signed this request (fresh, never seen), then the
 * device budget, then the provider tunnel with exactly the signed key, then
 * the rows, then the ACL, then the config. Used by the credential route and by
 * the enrollment-code route (where the caller is the code's creator).
 */
const enrollInto = <C, M>(
  caller: Named<C, Principal>,
  mesh: Named<M, MeshId>,
  proofs: { readonly owns: TenantOwnsResource<C, M>; readonly scope: KeyHasScope<C, "mesh:join"> },
  payload: EnrollPayload,
  beforeCreate: Effect.Effect<void, NotFound | ServiceUnavailable, MeshStore> = Effect.void,
) =>
  Effect.gen(function* () {
    const principal = caller.value;
    const store = yield* MeshStore;
    const ownership = yield* OwnershipStore;
    const upstream = yield* UpstreamMesh;
    const held = yield* deviceHoldsKey(
      caller,
      mesh,
      { purpose: "enroll", wgPublicKey: payload.wgPublicKey, installPublicKey: payload.installPublicKey, name: payload.name, signedAt: payload.signedAt, nonce: payload.nonce },
      payload.signature,
      null,
    ).pipe(Effect.catchAll(dependencyDown("mesh.claimSignedRequest")));
    if (held._tag !== "held") return yield* Effect.fail(signatureRefused(held._tag));
    const existing = yield* store.listDevices(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
    if (existing.some((device) => device.wgPublicKey === payload.wgPublicKey)) {
      return yield* Effect.fail(new Conflict({ message: "A device with this public key is already in the mesh" }));
    }
    const cidr = yield* store.cidrOf(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.cidrOf")));
    if (Option.isNone(cidr)) return yield* Effect.fail(unavailable());
    yield* beforeCreate;
    return yield* withSlot(tenantMayCreateDevice(caller, mesh), principal.tenantId, "device.perMesh", (mayCreate) =>
      Effect.uninterruptible(
        name(newDeviceId(), (device) =>
          Effect.gen(function* () {
            const tunnelId = newTunnelId();
            const created = yield* upstream
              .createTunnel(mesh, { owns: proofs.owns, scope: proofs.scope, mayCreate, holds: held.proof }, {
                tenantId: principal.tenantId,
                deviceId: device.value,
                routes: [cidr.value],
              })
              .pipe(Effect.mapError((error) => (error.status === 409 ? new Conflict({ message: "The tunnel could not be created for this mesh" }) : unavailable())));
            const createdAt = yield* now;
            const createdBy = actorRef(principal.actor);
            const row: MeshDeviceRow = {
              deviceId: device.value,
              meshId: mesh.value,
              tunnelId,
              name: payload.name,
              wgPublicKey: payload.wgPublicKey,
              installPublicKey: payload.installPublicKey,
              createdBy,
              createdAt,
            };
            const base = { tenantId: principal.tenantId, upstreamId: created.upstreamId, createdBy, createdAt, labels: {} };
            const undo = (event: string) =>
              Effect.gen(function* () {
                yield* upstream.discardCreatedTunnel(created).pipe(Effect.catchAll(() => logEvent("mesh_tunnel_discard_failed", { deviceId: device.value })));
                const at = yield* now;
                yield* ownership.markDeleted(principal.tenantId, "device", device.value, at).pipe(Effect.ignore);
                yield* ownership.markDeleted(principal.tenantId, "tunnel", tunnelId, at).pipe(Effect.ignore);
                yield* store.markDeviceDeleted(principal.tenantId, device.value, at).pipe(Effect.ignore);
                yield* logEvent(event, { deviceId: device.value });
              });
            yield* Effect.all([
              ownership.record({ ...base, kind: "tunnel", cmuxId: tunnelId, displayName: null }),
              ownership.record({ ...base, kind: "device", cmuxId: device.value, displayName: payload.name }),
              store.recordDevice(principal.tenantId, row),
            ]).pipe(
              Effect.tapError(() => undo("mesh_device_record_failed")),
              Effect.mapError(() => unavailable()),
            );
            // ACL first, then config: the device's rules exist before it learns its endpoint.
            yield* reconcileCurrent(caller, mesh, proofs.owns).pipe(Effect.tapError(() => undo("mesh_device_reconcile_failed")));
            return new DeviceEnrollment({ device: toDevice(row), tunnel: toTunnel(row, created.info) });
          }),
        ),
      ),
    );
  });

/** The creator recorded on a code (`user:<id>` or `key:<id>`), as the actor the enroll runs as. */
const actorOf = (createdBy: string): Option.Option<Principal["actor"]> => {
  const [kind, ...rest] = createdBy.split(":");
  const id = rest.join(":");
  if (kind === "user") return Option.map(Schema.decodeUnknownOption(UserId)(id), (userId) => ({ kind: "session" as const, userId }));
  if (kind === "key") return Option.map(Schema.decodeUnknownOption(ApiKeyId)(id), (keyId) => ({ kind: "api_key" as const, keyId }));
  return Option.none();
};

/**
 * The unauthenticated enrollment-code route (M2). The code is the credential:
 * found by its SHA-256 for this mesh, unused and unexpired, in a tenant with the
 * experiment on. The enroll then runs as the code's creator with only
 * `mesh:join` and `mesh:read`, so the device belongs to the creator. A session
 * creator must still be a member of the team. The code is used up only after
 * the signature is accepted, so a refused request leaves it valid.
 */
export const meshEnrollHandlers = HttpApiBuilder.group(CmuxVmApi, "meshEnroll", (handlers) =>
  handlers.handle("codeEnrollDevice", ({ path, payload }) =>
    Effect.gen(function* () {
      const config = yield* MeshConfig;
      if (!config.experiment) return yield* Effect.fail(experimentOff());
      const parsed = parseMeshId(path.meshId);
      if (Option.isNone(parsed)) return yield* Effect.fail(experimentOff());
      const store = yield* MeshStore;
      const codeSha256 = yield* sha256Hex(payload.code);
      const found = yield* store.findEnrollmentCode(codeSha256, parsed.value, yield* now).pipe(Effect.catchAll(dependencyDown("mesh.findEnrollmentCode")));
      if (Option.isNone(found) || !config.enabledFor(found.value.tenantId)) return yield* Effect.fail(experimentOff());
      const code = found.value;
      const actor = actorOf(code.createdBy);
      if (Option.isNone(actor)) return yield* Effect.fail(experimentOff());
      const creator = actor.value;
      if (creator.kind === "session") {
        const member = yield* (yield* TeamMembership).isMember(code.tenantId, creator.userId).pipe(Effect.mapError(() => unavailable()));
        if (!member) return yield* Effect.fail(experimentOff());
      }
      const principal: Principal = {
        tenantId: code.tenantId,
        actor: creator,
        scopes: new Set<Scope>(["mesh:join", "mesh:read"]),
        resourceAllowlist: null,
        credentialExpiresAt: code.expiresAt,
      };
      return yield* name(principal, (caller) =>
        Effect.gen(function* () {
          const scope = keyHasScope(caller, "mesh:join");
          if (scope === null) return yield* Effect.fail(missingScope("mesh:join"));
          yield* rateLimit(principal, "write");
          return yield* name(parsed.value, (mesh) =>
            audited(
              "device.create",
              mesh.value,
              Effect.gen(function* () {
                const owns = yield* tenantOwnsMesh(caller, mesh).pipe(Effect.catchAll(dependencyDown("ownership.find")));
                if (owns === null) return yield* Effect.fail(meshNotFound());
                const consume = Effect.gen(function* () {
                  const used = yield* store.consumeEnrollmentCode(codeSha256, mesh.value, yield* now).pipe(Effect.catchAll(dependencyDown("mesh.consumeEnrollmentCode")));
                  if (!used) return yield* Effect.fail(experimentOff());
                });
                const enrollment = yield* enrollInto(caller, mesh, { owns, scope }, payload, consume);
                yield* store.recordEnrollmentCodeDevice(codeSha256, enrollment.device.id).pipe(Effect.ignore);
                return enrollment;
              }),
              (enrollment) => enrollment.device.id,
            ),
          );
        }),
      ).pipe(Effect.provideService(CurrentPrincipal, principal));
    }),
  ),
);

export const meshHandlers = HttpApiBuilder.group(CmuxVmApi, "mesh", (handlers) =>
  handlers
    .handle("createMesh", ({ payload }) =>
      withMeshCaller("mesh:write", "write", (caller, scope) =>
        audited(
          "mesh.create",
          null,
          Effect.gen(function* () {
            const principal = caller.value;
            yield* requireAdmin(principal, "mesh:write");
            const store = yield* MeshStore;
            const ownership = yield* OwnershipStore;
            const upstream = yield* UpstreamMesh;
            return yield* withSlot(tenantMayCreateMesh(caller), principal.tenantId, "mesh.perTenant", (mayCreate) =>
              Effect.uninterruptible(
                name(newMeshId(), (mesh) =>
                  Effect.gen(function* () {
                    let cidr: string | null = null;
                    for (let attempt = 0; attempt < 8 && cidr === null; attempt++) {
                      const slot = Math.floor(Math.random() * MESH_SLOTS);
                      const candidate = slotCidr(slot);
                      const claimed = yield* store.claimSlot(principal.tenantId, mesh.value, slot, candidate).pipe(Effect.catchAll(dependencyDown("mesh.claimSlot")));
                      if (claimed) cidr = candidate;
                    }
                    if (cidr === null) return yield* Effect.fail(unavailable());
                    const claimedCidr = cidr;
                    const releaseSlot = store.releaseSlot(principal.tenantId, mesh.value).pipe(Effect.ignore);
                    const created = yield* upstream
                      .createNetwork(mesh, { scope, mayCreate }, { tenantId: principal.tenantId, cidr: claimedCidr })
                      .pipe(Effect.tapError(() => releaseSlot), Effect.mapError(() => unavailable()));
                    const createdAt = yield* now;
                    yield* ownership
                      .record({
                        tenantId: principal.tenantId,
                        kind: "mesh",
                        cmuxId: mesh.value,
                        upstreamId: created.upstreamId,
                        createdBy: actorRef(principal.actor),
                        createdAt,
                        displayName: payload.displayName ?? null,
                        labels: {},
                      })
                      .pipe(
                        Effect.tapError(() =>
                          upstream.discardCreatedNetwork(created).pipe(
                            Effect.catchAll(() => logEvent("mesh_network_discard_failed", { meshId: mesh.value })),
                            Effect.zipRight(releaseSlot),
                          ),
                        ),
                        Effect.mapError(() => unavailable()),
                      );
                    return toMesh(mesh.value, payload.displayName ?? null, claimedCidr, createdAt);
                  }),
                ),
              ),
            );
          }),
          (mesh) => mesh.id,
        ),
      ),
    )
    .handle("listMeshes", () =>
      withMeshCaller("mesh:read", "read", (caller) =>
        Effect.gen(function* () {
          const principal = caller.value;
          const ownership = yield* OwnershipStore;
          const store = yield* MeshStore;
          const rows = yield* ownership
            .listPage(principal.tenantId, "mesh", { limit: 100, after: null, only: principal.resourceAllowlist, labels: null })
            .pipe(Effect.catchAll(dependencyDown("ownership.list")));
          const items = yield* Effect.forEach(rows, (row) =>
            Effect.map(store.cidrOf(principal.tenantId, row.cmuxId).pipe(Effect.catchAll(dependencyDown("mesh.cidrOf"))), (cidr) =>
              toMesh(row.cmuxId, row.displayName, Option.getOrElse(cidr, () => ""), row.createdAt),
            ),
          );
          return new MeshList({ items });
        }),
      ),
    )
    .handle("getMesh", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:read", "read", (caller, mesh, proofs) =>
        Effect.gen(function* () {
          const ownership = yield* OwnershipStore;
          const store = yield* MeshStore;
          const row = yield* ownership.find(caller.value.tenantId, "mesh", mesh.value).pipe(Effect.catchAll(dependencyDown("ownership.find")));
          if (Option.isNone(row)) return yield* Effect.fail(meshNotFound());
          const cidr = yield* store.cidrOf(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.cidrOf")));
          return toMesh(mesh.value, proofs.owns.displayName, Option.getOrElse(cidr, () => ""), row.value.createdAt);
        }),
      ),
    )
    .handle("deleteMesh", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:write", "write", (caller, mesh, proofs) =>
        audited(
          "mesh.delete",
          mesh.value,
          Effect.gen(function* () {
            const principal = caller.value;
            yield* requireAdmin(principal, "mesh:write");
            const store = yield* MeshStore;
            const upstream = yield* UpstreamMesh;
            const devices = yield* store.listDevices(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
            const members = yield* store.listMembers(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listMembers")));
            if (devices.length > 0 || members.length > 0) {
              return yield* Effect.fail(new Conflict({ message: "Remove the mesh's devices and VMs first" }));
            }
            yield* upstream.deleteNetwork(mesh, proofs).pipe(
              Effect.catchIf((error) => error.status === 404, () => Effect.void),
              Effect.mapError((error) => (error.status === 409 ? new Conflict({ message: "The mesh still has members; retry shortly" }) : unavailable())),
            );
            const at = yield* now;
            yield* (yield* OwnershipStore).markDeleted(principal.tenantId, "mesh", mesh.value, at).pipe(Effect.catchAll(dependencyDown("ownership.delete")));
            yield* store.releaseSlot(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.releaseSlot")));
          }),
        ),
      ),
    )
    .handle("enrollDevice", ({ path, payload }) =>
      withOwnedMesh(path.meshId, "mesh:join", "write", (caller, mesh, proofs) =>
        audited(
          "device.create",
          mesh.value,
          enrollInto(caller, mesh, proofs, payload),
          (enrollment) => enrollment.device.id,
        ),
      ),
    )
    .handle("createEnrollmentCode", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:join", "write", (caller, mesh) =>
        audited(
          "enrollment_code.create",
          mesh.value,
          Effect.gen(function* () {
            const principal = caller.value;
            const store = yield* MeshStore;
            const config = yield* MeshConfig;
            const started = yield* Clock.currentTimeMillis;
            const recent = yield* store
              .enrollmentCodesSince(principal.tenantId, mesh.value, new Date(started - 3_600_000))
              .pipe(Effect.catchAll(dependencyDown("mesh.enrollmentCodesSince")));
            if (recent.length >= config.budgets.enrollmentCodesPerHour) {
              const oldest = recent.reduce((min, at) => (at < min ? at : min), recent[0] ?? new Date(started));
              return yield* Effect.fail(
                new QuotaExceeded({
                  message: `This mesh made ${recent.length} enrollment codes in the last hour; the limit is ${config.budgets.enrollmentCodesPerHour}`,
                  retryAfterSeconds: Math.max(1, Math.ceil((oldest.getTime() + 3_600_000 - started) / 1000)),
                  budget: "enrollmentCode.perMeshPerHour",
                }),
              );
            }
            // 128 random bits; only the SHA-256 is stored, the code is shown once.
            const code = `mec_${randomIdBody()}`;
            const createdAt = new Date(started);
            const expiresAt = new Date(started + ENROLLMENT_CODE_TTL_MS);
            yield* store
              .insertEnrollmentCode({
                codeSha256: yield* sha256Hex(code),
                tenantId: principal.tenantId,
                meshId: mesh.value,
                createdBy: actorRef(principal.actor),
                createdAt,
                expiresAt,
              })
              .pipe(Effect.catchAll(dependencyDown("mesh.insertEnrollmentCode")));
            return new EnrollmentCode({ code, meshId: MeshId_(mesh.value), expiresAt: expiresAt.toISOString() });
          }),
        ),
      ),
    )
    .handle("rotateDeviceKey", ({ path, payload }) =>
      withOwnedDevice(path.deviceId, "mesh:join", "write", (caller, device, proofs, row) =>
        audited(
          "device.rotate_key",
          device.value,
          Effect.gen(function* () {
            const tenantId = caller.value.tenantId;
            const store = yield* MeshStore;
            const upstream = yield* UpstreamMesh;
            if (row.installPublicKey === null) {
              return yield* Effect.fail(new Conflict({ message: "This device was enrolled without an install key; enroll it again to rotate its key" }));
            }
            const held = yield* deviceHoldsKey(
              caller,
              device,
              { purpose: "rotate-key", wgPublicKey: payload.newPublicKey, installPublicKey: row.installPublicKey, name: "", signedAt: payload.signedAt, nonce: payload.nonce },
              payload.signature,
              row.installPublicKey,
            ).pipe(Effect.catchAll(dependencyDown("mesh.claimSignedRequest")));
            if (held._tag !== "held") return yield* Effect.fail(signatureRefused(held._tag));
            const devices = yield* store.listDevices(tenantId, row.meshId).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
            if (devices.some((other) => other.wgPublicKey === payload.newPublicKey)) {
              return yield* Effect.fail(new Conflict({ message: "A device of this mesh already has this public key" }));
            }
            const info = yield* upstream
              .rotateTunnelKey(device, { ...proofs, holds: held.proof })
              .pipe(Effect.mapError((error) => (error.status === 404 ? deviceNotFound() : unavailable())));
            const at = yield* now;
            const recorded = yield* store.updateDeviceKey(tenantId, device.value, payload.newPublicKey, at).pipe(Effect.catchAll(dependencyDown("mesh.updateDeviceKey")));
            if (!recorded) {
              // The provider has the new key but the row could not take it (a concurrent enroll took the key): the operator reconciles.
              yield* logEvent("mesh_rotate_record_failed", { deviceId: device.value });
              return yield* Effect.fail(unavailable());
            }
            return toTunnel({ ...row, wgPublicKey: payload.newPublicKey }, info);
          }),
        ),
      ),
    )
    .handle("listDevices", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:read", "read", (caller, mesh) =>
        Effect.gen(function* () {
          const store = yield* MeshStore;
          const rows = yield* store.listDevices(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.listDevices")));
          // A tenant admin sees every device; any other principal only the devices it enrolled (cx-0op.4).
          const own = rows.filter((row) => enrolledBy(caller.value, row));
          const all = own.length === rows.length || (yield* isTenantAdmin(caller.value).pipe(Effect.mapError(() => unavailable())));
          return new DeviceList({ items: (all ? rows : own).map(toDevice) });
        }),
      ),
    )
    .handle("getDevice", ({ path }) => withOwnedDevice(path.deviceId, "mesh:read", "read", (_caller, _device, _proofs, row) => Effect.succeed(toDevice(row))))
    .handle("deleteDevice", ({ path }) =>
      withOwnedDevice(path.deviceId, "mesh:join", "write", (caller, device, proofs, row) =>
        audited(
          "device.delete",
          device.value,
          Effect.gen(function* () {
            const tenantId = caller.value.tenantId;
            const store = yield* MeshStore;
            const upstream = yield* UpstreamMesh;
            // Revocation closes first: deleting the tunnel ends access, and the provider deletes its rules with it.
            yield* upstream.deleteDeviceTunnel(device, proofs).pipe(
              Effect.catchIf((error) => error.status === 404, () => Effect.void),
              Effect.mapError(() => unavailable()),
            );
            const at = yield* now;
            const rules = yield* store.listRules(tenantId, row.meshId).pipe(Effect.catchAll(dependencyDown("mesh.listRules")));
            yield* Effect.forEach(
              rules.filter((rule) => rule.deviceId === device.value),
              (rule) => store.markRuleDeleted(tenantId, row.meshId, rule.key, at),
              { discard: true },
            ).pipe(Effect.catchAll(dependencyDown("mesh.markRuleDeleted")));
            const ownership = yield* OwnershipStore;
            yield* Effect.all([
              ownership.markDeleted(tenantId, "device", device.value, at),
              ownership.markDeleted(tenantId, "tunnel", row.tunnelId, at),
              store.markDeviceDeleted(tenantId, device.value, at),
            ]).pipe(Effect.catchAll(dependencyDown("mesh.deleteDevice")));
          }),
        ),
      ),
    )
    .handle("getDevicePeers", ({ path }) =>
      withOwnedDevice(path.deviceId, "mesh:join", "read", (caller, device, _proofs, row) =>
        Effect.gen(function* () {
          const store = yield* MeshStore;
          const tenantId = caller.value.tenantId;
          const acl = yield* store.currentAcl(tenantId, row.meshId).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
          const document = Option.match(acl, { onNone: () => EMPTY_ACL, onSome: (version) => version.document });
          const { result, members } = yield* compileFor(tenantId, row.meshId, document, false);
          const rules = result.ok ? result.rules : [];
          const addresses = new Map(members.map((member) => [member.vmId, member.ipv4]));
          const peers = [...peersOf(device.value, rules)].map(([vmId, allowed]) => ({
            kind: "vm" as const,
            id: VmId_(vmId),
            address: addresses.get(vmId) ?? null,
            allow: allowed.map((rule) =>
              rule.protocol === null ? { protocol: "any" as const } : rule.port === null ? { protocol: rule.protocol } : { protocol: rule.protocol, port: rule.port },
            ),
          }));
          return new PeerMap({
            deviceId: DeviceId_(device.value),
            meshId: MeshId_(row.meshId),
            aclVersion: Option.match(acl, { onNone: () => 0, onSome: (version) => version.version }),
            peers,
          });
        }),
      ),
    )
    .handle("getTunnel", ({ path }) =>
      withMeshCaller("mesh:read", "read", (caller, scope) =>
        Effect.gen(function* () {
          const parsed = parseTunnelId(path.tunnelId);
          if (Option.isNone(parsed)) return yield* Effect.fail(tunnelNotFound());
          const store = yield* MeshStore;
          const upstream = yield* UpstreamMesh;
          return yield* name(parsed.value, (tunnel) =>
            Effect.gen(function* () {
              const owns = yield* tenantOwnsTunnel(caller, tunnel).pipe(Effect.catchAll(dependencyDown("ownership.find")));
              if (owns === null) return yield* Effect.fail(tunnelNotFound());
              const row = yield* store.getDeviceByTunnel(caller.value.tenantId, tunnel.value).pipe(Effect.catchAll(dependencyDown("mesh.getDeviceByTunnel")));
              if (Option.isNone(row)) return yield* Effect.fail(tunnelNotFound());
              const acts = yield* callerActsOnTunnel(caller, tunnel, owns, row.value).pipe(Effect.mapError(() => unavailable()));
              if (acts === null) return yield* Effect.fail(tunnelNotFound());
              const info = yield* upstream
                .getTunnel(tunnel, { owns, scope, acts })
                .pipe(Effect.mapError((error) => (error.status === 404 ? tunnelNotFound() : unavailable())));
              return toTunnel(row.value, info);
            }),
          );
        }),
      ),
    )
    .handle("attachMeshVm", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:write", "write", (caller, mesh, proofs) =>
        audited(
          "mesh.vm.attach",
          mesh.value,
          Effect.gen(function* () {
            const vmScope = keyHasScope(caller, "vm:write");
            if (vmScope === null) return yield* Effect.fail(missingScope("vm:write"));
            const parsed = parseVmId(path.vmId);
            if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
            const store = yield* MeshStore;
            const upstream = yield* UpstreamMesh;
            const tenantId = caller.value.tenantId;
            return yield* name(parsed.value, (vm) =>
              Effect.gen(function* () {
                const ownsVm = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
                if (ownsVm === null) return yield* Effect.fail(vmNotFound());
                const current = yield* store.memberOf(tenantId, vm.value).pipe(Effect.catchAll(dependencyDown("mesh.memberOf")));
                if (Option.isSome(current) && current.value.meshId !== mesh.value) {
                  return yield* Effect.fail(new Conflict({ message: "This VM is already in another mesh" }));
                }
                let member = Option.getOrNull(current);
                if (member === null) {
                  const attached = yield* upstream
                    .attachVm(mesh, vm, { ownsMesh: proofs.owns, ownsVm, meshScope: proofs.scope, vmScope })
                    .pipe(
                      Effect.mapError((error) =>
                        error.status === 404 ? vmNotFound() : error.status === 409 ? new Conflict({ message: "This VM cannot join the mesh right now" }) : unavailable(),
                      ),
                    );
                  const row = { meshId: mesh.value, vmId: vm.value, ipv4: attached.ipv4, attachedAt: yield* now };
                  const inserted = yield* store.attachMember(tenantId, row).pipe(Effect.catchAll(dependencyDown("mesh.attachMember")));
                  if (!inserted) return yield* Effect.fail(new Conflict({ message: "This VM joined a mesh at the same time; retry" }));
                  member = row;
                }
                yield* reconcileCurrent(caller, mesh, proofs.owns);
                return new MeshMember({
                  meshId: MeshId_(member.meshId),
                  vmId: VmId_(member.vmId),
                  ipv4: member.ipv4,
                  attachedAt: member.attachedAt.toISOString(),
                });
              }),
            );
          }),
        ),
      ),
    )
    .handle("detachMeshVm", ({ path }) =>
      withOwnedMesh(path.meshId, "mesh:write", "write", (caller, mesh, proofs) =>
        audited(
          "mesh.vm.detach",
          mesh.value,
          Effect.gen(function* () {
            const vmScope = keyHasScope(caller, "vm:write");
            if (vmScope === null) return yield* Effect.fail(missingScope("vm:write"));
            const parsed = parseVmId(path.vmId);
            if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
            const store = yield* MeshStore;
            const upstream = yield* UpstreamMesh;
            const tenantId = caller.value.tenantId;
            return yield* name(parsed.value, (vm) =>
              Effect.gen(function* () {
                const ownsVm = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
                if (ownsVm === null) return yield* Effect.fail(vmNotFound());
                const current = yield* store.memberOf(tenantId, vm.value).pipe(Effect.catchAll(dependencyDown("mesh.memberOf")));
                if (Option.isNone(current) || current.value.meshId !== mesh.value) return yield* Effect.fail(vmNotFound());
                // The VM's rules go first: they name the VM, not the network, so leaving would not remove them.
                const rules = yield* ownedMeshRules(caller, mesh, proofs.owns).pipe(Effect.catchAll(dependencyDown("mesh.listRules")));
                yield* Effect.forEach(
                  rules.filter((proof) => proof.rule.vmId === vm.value),
                  (proof) =>
                    Effect.gen(function* () {
                      yield* upstream.deleteRule(proof).pipe(
                        Effect.catchIf((error) => error.status === 404, () => Effect.void),
                        Effect.mapError(() => unavailable()),
                      );
                      yield* store.markRuleDeleted(tenantId, mesh.value, proof.rule.key, yield* now).pipe(Effect.catchAll(dependencyDown("mesh.markRuleDeleted")));
                    }),
                  { concurrency: 8, discard: true },
                );
                yield* upstream.detachVm(vm, { ownsVm, vmScope }).pipe(
                  Effect.catchIf((error) => error.status === 404, () => Effect.void),
                  Effect.mapError(() => unavailable()),
                );
                yield* store.detachMember(tenantId, mesh.value, vm.value, yield* now).pipe(Effect.catchAll(dependencyDown("mesh.detachMember")));
              }),
            );
          }),
        ),
      ),
    )
    .handle("getMeshAcl", ({ path }) =>
      withOwnedMesh(path.meshId, "acl:read", "read", (caller, mesh) =>
        Effect.gen(function* () {
          const store = yield* MeshStore;
          const acl = yield* store.currentAcl(caller.value.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
          return Option.match(acl, {
            onNone: () => new Acl({ meshId: MeshId_(mesh.value), version: 0, rules: [], updatedAt: null }),
            onSome: (row) =>
              new Acl({ meshId: MeshId_(mesh.value), version: row.version, rules: row.document.rules, updatedAt: row.createdAt.toISOString() }),
          });
        }),
      ),
    )
    .handle("putMeshAcl", ({ path, payload }) =>
      withOwnedMesh(path.meshId, "acl:write", "write", (caller, mesh, proofs) =>
        audited(
          "acl.apply",
          mesh.value,
          Effect.gen(function* () {
            const principal = caller.value;
            yield* requireAdmin(principal, "acl:write");
            const store = yield* MeshStore;
            const config = yield* MeshConfig;
            const started = yield* Clock.currentTimeMillis;
            const windowStart = new Date(started - 60_000);
            const recent = yield* store.aclVersionsSince(principal.tenantId, mesh.value, windowStart).pipe(Effect.catchAll(dependencyDown("mesh.aclVersionsSince")));
            if (recent.length >= config.budgets.aclAppliesPerMinute) {
              const oldest = recent.reduce((min, at) => (at < min ? at : min), recent[0] ?? new Date(started));
              return yield* Effect.fail(
                new QuotaExceeded({
                  message: `This mesh's ACL changed ${recent.length} times in the last minute; the limit is ${config.budgets.aclAppliesPerMinute}`,
                  retryAfterSeconds: Math.max(1, Math.ceil((oldest.getTime() + 60_000 - started) / 1000)),
                  budget: "aclApply.perMeshPerMinute",
                }),
              );
            }
            const current = yield* store.currentAcl(principal.tenantId, mesh.value).pipe(Effect.catchAll(dependencyDown("mesh.currentAcl")));
            const currentVersion = Option.match(current, { onNone: () => 0, onSome: (row) => row.version });
            if (payload.expectedVersion !== currentVersion) {
              return yield* Effect.fail(new Conflict({ message: `The ACL is at version ${currentVersion}; read it and apply again` }));
            }
            const document: AclDocument = { rules: payload.rules };
            const { result } = yield* compileFor(principal.tenantId, mesh.value, document, true);
            const desired = yield* compiled(result);
            const sha256 = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(document)))).pipe(
              Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
            );
            const version = currentVersion + 1;
            const inserted = yield* store
              .insertAcl(principal.tenantId, mesh.value, { version, document, sha256, author: actorRef(principal.actor), createdAt: new Date(started) })
              .pipe(Effect.catchAll(dependencyDown("mesh.insertAcl")));
            if (!inserted) return yield* Effect.fail(new Conflict({ message: "Another ACL change was applied at the same time; read it and apply again" }));
            const applied = yield* reconcile(caller, mesh, proofs.owns, desired);
            const finished = yield* Clock.currentTimeMillis;
            return new AclApplied({
              meshId: MeshId_(mesh.value),
              version,
              ruleCount: applied.ruleCount,
              rulesCreated: applied.created,
              rulesDeleted: applied.deleted,
              applyMs: Math.max(0, Math.round(finished - started)),
            });
          }),
        ),
      ),
    ),
);
