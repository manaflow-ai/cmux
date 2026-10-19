/* oxlint-disable gdp-ts/no-type-assertion, gdp-ts/no-proof-assertion */
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Layer, Option } from "effect";
import { authenticateCompat } from "../auth/middleware.ts";
import { AuditStore, OwnershipStore, type OwnedResource, type OwnershipStoreService, type AuditStoreService, ApiKeyStore } from "../db/stores.ts";
import { ServiceKeys } from "../auth/service-keys.ts";
import { SessionVerifier, TeamMembership } from "../auth/credentials.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { TenantLimits } from "../limits/service.ts";
import { IdentityId, newIdentityId, newSnapshotId, newVmId, parseIdentityId, parseSnapshotId, parseVmId, UpstreamId, type ResourceId, UserId } from "../lib/ids.ts";
import { keyHasScope } from "../proofs/key-has-scope.ts";
import { tenantMayCreate } from "../proofs/tenant-may-create.ts";
import { Entitlements } from "../proofs/tenant-may-create.ts";
import { TenantPolicy } from "../policy.ts";
import { tenantOwnsIdentity, tenantOwnsSnapshot, tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { CompatUpstream } from "../upstream/compat.ts";
import { IdentityStore, type IdentityStoreService } from "./identity-store.ts";
import type { CompatUpstreamService } from "../upstream/compat.ts";
import { UsageRecorder } from "../metering/recorder.ts";
import { rateLimit } from "../handlers/common.ts";

type CompatServices = CompatUpstream | OwnershipStore | AuditStore | IdentityStore | TenantLimits | Entitlements | TenantPolicy | ApiKeyStore | ServiceKeys | SessionVerifier | TeamMembership | UsageRecorder;
const error = (status: number, code: string, message: string) => Response.json({ code, message }, { status });
const notFound = (message = "Not found") => error(404, "NOT_FOUND", message);
const forbidden = (message = "Forbidden") => error(403, "FORBIDDEN", message);
const unavailable = () => error(503, "SERVICE_UNAVAILABLE", "The service is temporarily unavailable");
const notAvailable = () => error(404, "NOT_AVAILABLE", "This operation is not available");
const providerError = (status: number | null): Response =>
  status === 404 ? notFound() : status === 400 ? error(400, "BAD_REQUEST", "The request was not accepted") : status === 401 ? error(401, "UNAUTHORIZED", "The upstream credential was rejected") : status === 402 ? error(402, "PAYMENT_REQUIRED", "This team is not entitled to create VMs") : status === 409 ? error(409, "CONFLICT", "The resource is not in a state that permits this operation") : status === 429 ? error(429, "RATE_LIMITED", "Too many requests; retry later") : unavailable();
const copyResponse = (response: Response): Response => {
  if (response.status === 101 && response.webSocket !== null) return new Response(null, { status: 101, webSocket: response.webSocket });
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers: response.headers });
};
const parseJson = async (response: Response): Promise<Record<string, unknown> | null> => {
  try {
    const value: unknown = await response.clone().json();
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
};
const parseRequestJson = async (request: Request): Promise<Record<string, unknown> | null> => {
  try {
    const value: unknown = await request.clone().json();
    return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null;
  } catch {
    return null;
  }
};
const stringField = (value: Record<string, unknown> | null, key: string): string | null => (typeof value?.[key] === "string" ? value[key] : null);
const hash = (value: string) => Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).pipe(Effect.map((bytes) => Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("")));
const idFrom = (prefix: string) => `${prefix}${crypto.randomUUID()}`;
const hasField = (value: unknown, field: string): boolean => {
  if (Array.isArray(value)) return value.some((item) => hasField(item, field));
  if (typeof value !== "object" || value === null) return false;
  return Object.entries(value).some(([key, child]) => key === field || hasField(child, field));
};
const fingerprint = (value: unknown) => Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)))).pipe(Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")));
const findResourceRefs = (value: unknown): ReadonlyArray<{ readonly kind: "vm" | "identity"; readonly id: string }> => {
  const found: Array<{ readonly kind: "vm" | "identity"; readonly id: string }> = [];
  const walk = (current: unknown): void => {
    if (Array.isArray(current)) { for (const item of current) walk(item); return; }
    if (typeof current !== "object" || current === null) return;
    for (const [key, child] of Object.entries(current)) {
      if ((key === "vmId" || key === "identityId") && typeof child === "string") found.push({ kind: key === "vmId" ? "vm" : "identity", id: child });
      walk(child);
    }
  };
  walk(value);
  return found;
};
type OwnedVmResult = { readonly caller: Named<never, Principal>; readonly vm: Named<never, import("../lib/ids.ts").VmId>; readonly owns: TenantOwnsResource<never, ResourceId>; readonly row: OwnedResource };
type OwnedSnapshotResult = { readonly caller: Named<never, Principal>; readonly snapshot: Named<never, import("../lib/ids.ts").SnapshotId>; readonly owns: TenantOwnsResource<never, ResourceId>; readonly row: OwnedResource };
const scopeFor = (method: string, parts: ReadonlyArray<string>): Scope | null => {
  if (parts[0] === "vms") {
    if (parts.length === 1) return method === "GET" ? "vm:read" : "vm:write";
    if (parts[2] === "exec-await") return "vm:exec";
    if (parts[2] === "fs") return "vm:files";
    if (parts[2] === "pty") return "vm:terminal";
    if (parts[2] === "snapshot") return "snapshot:write";
    return method === "GET" ? "vm:read" : "vm:write";
  }
  if (parts[0] === "snapshots") return method === "GET" ? "snapshot:read" : "snapshot:write";
  if (parts[0] === "identities") return method === "GET" ? "vm:read" : "vm:write";
  return null;
};
const authError = (cause: unknown): Response => {
  if (typeof cause === "object" && cause !== null && "_tag" in cause && cause._tag === "Forbidden") return forbidden("This credential is not allowed");
  if (typeof cause === "object" && cause !== null && "_tag" in cause && cause._tag === "ServiceUnavailable") return unavailable();
  return error(401, "UNAUTHORIZED", "A valid API key or Stack access token is required");
};

export const makeFreestyleCompatHandler = (services: Layer.Layer<CompatServices>, options: { readonly publicSnapshotIds: ReadonlyArray<string> }) => async (request: Request): Promise<Response> => Effect.runPromise(Effect.provide(handle(request, options), services) as Effect.Effect<Response, unknown, never>).catch(() => unavailable());

const handle = (request: Request, options: { readonly publicSnapshotIds: ReadonlyArray<string> }): Effect.Effect<Response, unknown, unknown> => Effect.gen(function* () {
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/v5/")) return notAvailable();
  if (url.pathname.startsWith("/v5/background-requests")) return notFound();
  const parts = url.pathname.slice(4).split("/").filter(Boolean).map(decodeURIComponent);
  const identityToken = request.headers.get("x-freestyle-identity-access-token");
  const scope = scopeFor(request.method, parts);
  const upstream = yield* CompatUpstream;
  const ownership = yield* OwnershipStore;
  const audit = yield* AuditStore;
  const identities = yield* IdentityStore;
  const usage = yield* UsageRecorder;
  const now = new Date(yield* Clock.currentTimeMillis);
  if (identityToken !== null) {
    if ((scope !== "vm:exec" && scope !== "vm:terminal") || parts[0] !== "vms" || parts[1] === undefined) return notFound();
    return yield* identityExec(request, parts, identityToken, upstream, ownership, identities, audit, usage, now);
  }
  const bearer = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/u)?.[1];
  if (bearer === undefined) return error(401, "UNAUTHORIZED", "A valid API key or Stack access token is required");
  const auth = yield* Effect.either(authenticateCompat(bearer, request.headers));
  if (auth._tag === "Left") return authError(auth.left);
  const principal = auth.right;
  if (scope === null) return notAvailable();
  if (!principal.scopes.has(scope)) return forbidden(`This credential lacks the ${scope} scope`);
  if (parts[0] === "vms" && parts.length === 1 && request.method === "POST") return yield* createVm(request, principal, upstream, ownership, audit, usage, now, options.publicSnapshotIds);
  if (parts[0] === "vms" && parts.length === 1 && request.method === "GET") return yield* listVms(principal, upstream, ownership);
  if (parts[0] === "snapshots" && parts.length === 1 && request.method === "GET") return yield* listSnapshots(principal, upstream, ownership);
  if (parts[0] === "identities" && parts.length === 1) return yield* identityCollection(request, principal, upstream, ownership, audit, now);
  if (parts[0] === "identities") return yield* identityResource(request, parts.slice(1), principal, upstream, ownership, identities, audit, now);
  if (parts[0] === "snapshots" && parts[1] !== undefined) return yield* snapshotResource(request, parts[1], principal, upstream, ownership, audit, now);
  if (parts[0] === "vms" && parts[1] !== undefined) return yield* vmResource(request, parts.slice(1), principal, upstream, ownership, identities, audit, usage, now);
  return notAvailable();
}).pipe(Effect.catchAll(() => Effect.succeed(unavailable())));

const ownedVm = (principal: Principal, upstreamId: string): Effect.Effect<OwnedVmResult | null, unknown, OwnershipStore> => Effect.gen(function* () {
  const store = yield* OwnershipStore;
  const row = yield* store.findByUpstream(principal.tenantId, "vm", upstreamId);
  if (Option.isNone(row)) return null;
  const parsed = parseVmId(row.value.cmuxId);
  if (Option.isNone(parsed)) return null;
  return yield* name(principal, (caller) => name(parsed.value, (vm) => tenantOwnsVm(caller, vm).pipe(Effect.map((owns) => owns === null ? null : { caller: caller as unknown as Named<never, Principal>, vm: vm as unknown as Named<never, import("../lib/ids.ts").VmId>, owns: owns as unknown as TenantOwnsResource<never, ResourceId>, row: row.value }))));
});
const ownedSnapshot = (principal: Principal, upstreamId: string): Effect.Effect<OwnedSnapshotResult | null, unknown, OwnershipStore> => Effect.gen(function* () {
  const store = yield* OwnershipStore;
  const row = yield* store.findByUpstream(principal.tenantId, "snapshot", upstreamId);
  if (Option.isNone(row)) return null;
  const parsed = parseSnapshotId(row.value.cmuxId);
  if (Option.isNone(parsed)) return null;
  return yield* name(principal, (caller) => name(parsed.value, (snapshot) => tenantOwnsSnapshot(caller, snapshot).pipe(Effect.map((owns) => owns === null ? null : { caller: caller as unknown as Named<never, Principal>, snapshot: snapshot as unknown as Named<never, import("../lib/ids.ts").SnapshotId>, owns: owns as unknown as TenantOwnsResource<never, ResourceId>, row: row.value }))));
});

const listVms = (principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService) => Effect.gen(function* () {
  const rows = yield* ownership.listPage(principal.tenantId, "vm", { limit: 10_000, after: null, only: principal.resourceAllowlist, labels: null });
  const vms: unknown[] = [];
  for (const row of rows) {
    const parsed = parseVmId(row.cmuxId);
    if (Option.isNone(parsed)) continue;
    const result = yield* name(principal, (caller) => name(parsed.value, (vm) => tenantOwnsVm(caller, vm).pipe(Effect.flatMap((owns) => owns === null ? Effect.succeed(null) : upstream.forwardOwned(owns as unknown as import("../proofs/tenant-owns-resource.ts").TenantOwnsResource<never, import("../lib/ids.ts").ResourceId>, { request: new Request("https://vm.test", { method: "GET" }), template: "/v5/vms/{id}", operation: "list_vms" }).pipe(Effect.flatMap((response) => response.ok ? Effect.promise(() => response.json() as Promise<unknown>) : Effect.succeed(null)))))));
    if (result !== null) vms.push(result);
  }
  const stateCount = (state: string) => vms.filter((vm) => typeof vm === "object" && vm !== null && Reflect.get(vm, "state") === state).length;
  return Response.json({ vms, totalCount: vms.length, runningCount: stateCount("running"), startingCount: stateCount("starting"), pausingCount: stateCount("pausing"), pausedCount: stateCount("paused"), stoppedCount: stateCount("stopped") });
});
const listSnapshots = (principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService) => Effect.gen(function* () {
  const rows = yield* ownership.listPage(principal.tenantId, "snapshot", { limit: 10_000, after: null, only: principal.resourceAllowlist, labels: null });
  const snapshots: unknown[] = [];
  for (const row of rows) {
    const parsed = parseSnapshotId(row.cmuxId);
    if (Option.isNone(parsed)) continue;
    const value = yield* name(principal, (caller) => name(parsed.value, (snapshot) => tenantOwnsSnapshot(caller, snapshot).pipe(Effect.flatMap((owns) => owns === null ? Effect.succeed(null) : upstream.forwardOwned(owns as unknown as import("../proofs/tenant-owns-resource.ts").TenantOwnsResource<never, import("../lib/ids.ts").ResourceId>, { request: new Request("https://vm.test", { method: "GET" }), template: "/v5/snapshots/{id}", operation: "list_snapshots" }).pipe(Effect.flatMap((response) => response.ok ? Effect.promise(() => response.json() as Promise<unknown>) : Effect.succeed(null)))))));
    if (value !== null) snapshots.push(value);
  }
  return Response.json({ snapshots, totalCount: snapshots.length });
});

const createVm = (request: Request, principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService, audit: AuditStoreService, usage: { readonly record: (event: import("../metering/recorder.ts").UsageEvent) => Effect.Effect<void> }, now: Date, publicSnapshotIds: ReadonlyArray<string>) => Effect.gen(function* () {
  if (principal.resourceAllowlist !== null) return forbidden("A key limited to specific resources cannot create VMs");
  yield* rateLimit(principal, "write");
  const limits = yield* TenantLimits;
  const idempotencyKey = request.headers.get("idempotency-key");
  const scopedKey = idempotencyKey === null ? null : yield* fingerprint([principal.actor.kind, idempotencyKey]);
  if (scopedKey !== null) {
    const claim = yield* limits.begin(principal.tenantId, scopedKey, yield* fingerprint(["v5.createVm", yield* Effect.promise(() => request.clone().text())]));
    if (claim.state === "mismatch") return error(409, "CONFLICT", "This Idempotency-Key was already used with a different request");
    if (claim.state === "in_progress") return error(409, "CONFLICT", "A request with this Idempotency-Key is still running; retry shortly");
  }
  const body = (yield* Effect.promise(() => request.clone().json().catch(() => ({})))) as Record<string, unknown>;
  const snapshotId = typeof body.snapshotId === "string" ? body.snapshotId : null;
  if (snapshotId !== null) {
    const owned = snapshotId.startsWith("sh-") ? yield* ownership.findByUpstream(principal.tenantId, "snapshot", snapshotId) : Option.none();
    const publicBase = /^(?:freestyle\/ubuntu(?:-sm|-lg|-xl|-2xl|-3xl)?|freestyle\/busybox)$/u.test(snapshotId);
    if (Option.isNone(owned) && !publicBase && !publicSnapshotIds.includes(snapshotId)) return notFound();
  }
  if (body.reassignSlug === true) return error(400, "BAD_REQUEST", "reassignSlug is not available");
  if (body.tls !== undefined) return notFound();
  if (Array.isArray(body.vpcs) && body.vpcs.length > 0 || Array.isArray(body.networks) && body.networks.length > 0) return notFound();
  if (hasField(body.firewall, "vpcId") || hasField(body.firewall, "tunnelId")) return notFound();
  const firewallRefs = findResourceRefs(body.firewall);
  for (const ref of firewallRefs) {
    const kind = ref.kind === "identity" ? "identity" : "vm";
    const found = yield* ownership.findByUpstream(principal.tenantId, kind, ref.id);
    if (Option.isNone(found)) return notFound();
  }
  const requestBody = { ...body, metadata: { ...(typeof body.metadata === "object" && body.metadata !== null ? body.metadata : {}), cmuxTenant: principal.tenantId } };
  return yield* name(principal, (caller) => {
    const scope = keyHasScope(caller, "vm:write");
    if (scope === null) return Effect.succeed(forbidden("This credential lacks the vm:write scope"));
    return Effect.gen(function* () {
      const decision = yield* tenantMayCreate(caller, "vm");
      if (decision._tag === "not_entitled") return error(402, "PAYMENT_REQUIRED", "This team is not entitled to create VMs");
      if (decision._tag === "over_quota") return error(429, "QUOTA_EXCEEDED", "This team has reached its VM quota");
      const limits = yield* TenantLimits;
      const response = yield* upstream.forwardCreate(caller, decision.proof, { request: new Request(request.url, { method: "POST", headers: request.headers, body: JSON.stringify(requestBody) }), template: "/v5/vms", operation: "create_vm" }).pipe(Effect.mapError((failure) => providerError(failure.status)));
      if (!response.ok) { yield* limits.release(principal.tenantId, decision.proof.reservationId).pipe(Effect.ignore); return providerError(response.status); }
      const data = yield* Effect.promise(() => parseJson(response));
      const providerId = stringField(data, "id");
      if (providerId === null) return unavailable();
      const cmuxId = newVmId();
      yield* ownership.record({ tenantId: principal.tenantId, kind: "vm", cmuxId, upstreamId: UpstreamId.make(providerId), createdBy: actorRef(principal.actor), createdAt: now, displayName: typeof data?.displayName === "string" ? data.displayName : null, labels: {} }).pipe(Effect.mapError(() => unavailable()));
      yield* limits.release(principal.tenantId, decision.proof.reservationId).pipe(Effect.ignore);
      const resources = typeof data?.resources === "object" && data.resources !== null ? data.resources as Record<string, unknown> : {};
      yield* usage.record({ kind: "vm_started", tenantId: principal.tenantId, upstreamVmId: providerId, at: now, vcpus: typeof resources.cpu === "number" ? resources.cpu : 0, memoryMb: typeof resources.memory === "number" ? resources.memory : 0, storageMb: typeof resources.storage === "number" ? resources.storage : 0 }).pipe(Effect.ignore);
      yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: "v5.vm.create", cmuxId, outcome: "ok", at: now }).pipe(Effect.ignore);
      if (scopedKey !== null) yield* limits.advance(principal.tenantId, scopedKey, { phase: "done", vmId: cmuxId }).pipe(Effect.ignore);
      return copyResponse(response);
    });
  });
});

const vmResource = (request: Request, parts: ReadonlyArray<string>, principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService, identities: IdentityStoreService, audit: AuditStoreService, usage: { readonly record: (event: import("../metering/recorder.ts").UsageEvent) => Effect.Effect<void> }, now: Date) => Effect.gen(function* () {
  const id = parts[0];
  if (id === undefined) return notFound();
  const owned = yield* ownedVm(principal, id);
  if (owned === null) return notFound();
  if (parts[1] === "networks") return notFound();
  const suffix = parts.slice(1).join("/");
  const allowed = request.method === "GET" && (suffix === "" || suffix === "fs/dir" || suffix === "fs/exists" || suffix === "fs/read" || suffix === "fs/stat" || suffix === "pty" || suffix === "pty/sessions" || suffix.startsWith("pty/sessions/"))
    || request.method === "POST" && ["start", "pause", "exec-await", "snapshot", "resize", "fs/mkdir", "fs/uploads"].includes(suffix)
    || request.method === "PUT" && ["fs/write", "networks"].includes(suffix)
    || request.method === "PATCH" && suffix === ""
    || request.method === "DELETE" && (suffix === "" || suffix.startsWith("fs/") || suffix.startsWith("pty/sessions/"));
  if (!allowed) return notAvailable();
  const encodedSuffix = parts.slice(1).map(encodeURIComponent).join("/");
  const template = encodedSuffix.length === 0 ? "/v5/vms/{id}" : `/v5/vms/{id}/${encodedSuffix}`;
  let forwardRequest = request;
  if (request.method === "PATCH" && suffix === "") {
    const body = yield* Effect.promise(() => parseRequestJson(request));
    if (body?.reassignSlug === true) return error(400, "BAD_REQUEST", "reassignSlug is not available");
    if (body?.tls !== undefined || body?.vpcs !== undefined || body?.networks !== undefined) return notFound();
    forwardRequest = new Request(request.url, { method: request.method, headers: request.headers, body: JSON.stringify({ ...body, metadata: { ...(typeof body?.metadata === "object" && body.metadata !== null ? body.metadata : {}), cmuxTenant: principal.tenantId } }) });
  }
  let snapshotReservation: string | null = null;
  if (parts[1] === "snapshot" && request.method === "POST") {
    const decision = yield* name(principal, (caller) => tenantMayCreate(caller, "snapshot"));
    if (decision._tag === "not_entitled") return error(402, "PAYMENT_REQUIRED", "This team is not entitled to create snapshots");
    if (decision._tag === "over_quota") return error(429, "QUOTA_EXCEEDED", "This team has reached its snapshot quota");
    snapshotReservation = decision.proof.reservationId;
  }
  if (request.method === "DELETE" && suffix === "") yield* identities.revokeGrantsForVm(principal.tenantId, owned.vm.value, now).pipe(Effect.mapError(() => unavailable()));
  let response = yield* upstream.forwardOwned(owned.owns, { request: forwardRequest, template, operation: `v5.vm.${request.method.toLowerCase()}` }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  if (response.status === 409 && parts[1] === "exec-await") {
    const started = yield* upstream.forwardOwned(owned.owns, { request: new Request(request.url, { method: "POST", headers: request.headers }), template: "/v5/vms/{id}/start", operation: "v5.vm.start" }).pipe(Effect.mapError((failure) => providerError(failure.status)));
    const startData = yield* Effect.promise(() => parseJson(started));
    const startResources = typeof startData?.resources === "object" && startData.resources !== null ? startData.resources as Record<string, unknown> : {};
    yield* usage.record({ kind: "vm_started", tenantId: principal.tenantId, upstreamVmId: owned.row.upstreamId, at: now, vcpus: typeof startResources.cpu === "number" ? startResources.cpu : 0, memoryMb: typeof startResources.memory === "number" ? startResources.memory : 0, storageMb: typeof startResources.storage === "number" ? startResources.storage : 0 }).pipe(Effect.ignore);
    response = yield* upstream.forwardOwned(owned.owns, { request: forwardRequest, template, operation: "v5.vm.exec-await.retry" }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  }
  if (response.status === 409 && request.method === "PATCH") return error(400, "BAD_REQUEST", "The requested VM update is not available");
  if (response.ok && parts[1] === "snapshot") {
    const data = yield* Effect.promise(() => parseJson(response));
    const snapshotId = stringField(data, "snapshotId");
    if (snapshotId !== null) {
      const cmuxId = newSnapshotId();
      yield* ownership.record({ tenantId: principal.tenantId, kind: "snapshot", cmuxId, upstreamId: UpstreamId.make(snapshotId), createdBy: actorRef(principal.actor), createdAt: now, displayName: null, labels: {} }).pipe(Effect.mapError(() => unavailable()));
      yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: "v5.snapshot.create", cmuxId, outcome: "ok", at: now }).pipe(Effect.ignore);
    }
  }
  if (snapshotReservation !== null) yield* TenantLimits.pipe(Effect.flatMap((limits) => limits.release(principal.tenantId, snapshotReservation as string))).pipe(Effect.ignore);
  if (request.method === "DELETE" && response.ok) yield* ownership.markDeleted(principal.tenantId, "vm", owned.row.cmuxId, now).pipe(Effect.ignore);
  if (["POST", "PATCH", "PUT", "DELETE"].includes(request.method)) yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: `v5.vm.${request.method.toLowerCase()}`, cmuxId: owned.row.cmuxId, outcome: response.ok ? "ok" : `HTTP_${response.status}`, at: now }).pipe(Effect.ignore);
  if (response.ok && ["start", "pause", "resize"].includes(parts[1] ?? "")) {
    const data = yield* Effect.promise(() => parseJson(response));
    const resources = typeof data?.resources === "object" && data.resources !== null ? data.resources as Record<string, unknown> : {};
    const vcpus = typeof resources.cpu === "number" ? resources.cpu : 0;
    const memoryMb = typeof resources.memory === "number" ? resources.memory : 0;
    const storageMb = typeof resources.storage === "number" ? resources.storage : 0;
    if (parts[1] === "start") yield* usage.record({ kind: "vm_started", tenantId: principal.tenantId, upstreamVmId: owned.row.upstreamId, at: now, vcpus, memoryMb, storageMb }).pipe(Effect.ignore);
    if (parts[1] === "pause") yield* usage.record({ kind: "vm_stopped", tenantId: principal.tenantId, upstreamVmId: owned.row.upstreamId, at: now, reason: "pause" }).pipe(Effect.ignore);
    if (parts[1] === "resize") yield* usage.record({ kind: "vm_resized", tenantId: principal.tenantId, upstreamVmId: owned.row.upstreamId, at: now, vcpus, memoryMb, storageMb }).pipe(Effect.ignore);
  }
  if (response.ok && request.method === "DELETE") yield* usage.record({ kind: "vm_stopped", tenantId: principal.tenantId, upstreamVmId: owned.row.upstreamId, at: now, reason: "delete" }).pipe(Effect.ignore);
  return copyResponse(response);
});
const snapshotResource = (request: Request, id: string, principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService, audit: AuditStoreService, now: Date) => Effect.gen(function* () {
  const owned = yield* ownedSnapshot(principal, id);
  if (owned === null) return notFound();
  const response = yield* upstream.forwardOwned(owned.owns, { request, template: "/v5/snapshots/{id}", operation: `v5.snapshot.${request.method.toLowerCase()}` }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  if (request.method === "DELETE" && response.ok) yield* ownership.markDeleted(principal.tenantId, "snapshot", owned.row.cmuxId, now).pipe(Effect.ignore);
  return copyResponse(response);
});

const identityCollection = (request: Request, principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService, audit: AuditStoreService, now: Date) => Effect.gen(function* () {
  if (request.method === "GET") {
    const rows = yield* ownership.listPage(principal.tenantId, "identity", { limit: 1000, after: null, only: principal.resourceAllowlist, labels: null });
    const values: unknown[] = [];
    for (const row of rows) {
      const parsed = parseIdentityId(row.cmuxId);
      if (Option.isNone(parsed)) continue;
      const value = yield* name(principal, (caller) => name(parsed.value, (identity) => tenantOwnsIdentity(caller, identity).pipe(Effect.flatMap((owns) => owns === null ? Effect.succeed(null) : upstream.forwardOwned(owns as unknown as TenantOwnsResource<never, ResourceId>, { request: new Request("https://vm.test", { method: "GET" }), template: "/v5/identities/{id}", operation: "list_identities" }).pipe(Effect.flatMap((response) => response.ok ? Effect.promise(() => response.json() as Promise<unknown>) : Effect.succeed(null)))))));
      if (value !== null) values.push(value);
    }
    return Response.json({ identities: values, total: values.length });
  }
  return yield* name(principal, (caller) => {
    const proof = keyHasScope(caller, "vm:write");
    if (proof === null) return Effect.succeed(forbidden("This credential lacks the vm:write scope"));
    return Effect.gen(function* () {
      const response = yield* upstream.forwardAuthorized(caller, proof, { request, template: "/v5/identities", operation: "create_identity" }).pipe(Effect.mapError((failure) => providerError(failure.status)));
      if (!response.ok) return copyResponse(response);
      const data = yield* Effect.promise(() => parseJson(response));
      const providerId = stringField(data, "id");
      if (providerId === null) return unavailable();
      const cmuxId = newIdentityId();
      yield* ownership.record({ tenantId: principal.tenantId, kind: "identity", cmuxId, upstreamId: UpstreamId.make(providerId), createdBy: actorRef(principal.actor), createdAt: now, displayName: null, labels: {} }).pipe(Effect.mapError(() => unavailable()));
      yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: "v5.identity.create", cmuxId, outcome: "ok", at: now }).pipe(Effect.ignore);
      return copyResponse(response);
    });
  });
});

const identityResource = (request: Request, parts: ReadonlyArray<string>, principal: Principal, upstream: CompatUpstreamService, ownership: OwnershipStoreService, identities: IdentityStoreService, audit: AuditStoreService, now: Date) => Effect.gen(function* () {
  const id = parts[0];
  if (id === undefined) return notFound();
  const row = yield* ownership.findByUpstream(principal.tenantId, "identity", id);
  if (Option.isNone(row)) return notFound();
  const parsed = parseIdentityId(row.value.cmuxId);
  if (Option.isNone(parsed)) return notFound();
  const result = (yield* name(principal, (caller) => name(parsed.value, (identity) => tenantOwnsIdentity(caller, identity).pipe(Effect.map((owns) => owns === null ? null : { owns: owns as unknown as TenantOwnsResource<never, ResourceId>, identity: identity as unknown as import("@gdp-ts/core").Named<never, IdentityId> }))))) as { readonly owns: TenantOwnsResource<never, ResourceId>; readonly identity: import("@gdp-ts/core").Named<never, IdentityId> } | null;
  if (result === null) return notFound();
  const tail = parts.slice(1);
  if (tail[0] === "permissions" && tail[1] === "vm") return yield* identityPermission(request, tail.slice(2), principal, result.owns, parsed.value, ownership, identities, upstream, audit, now);
  if (tail[0] === "tokens") return yield* identityToken(request, tail.slice(1), principal, result.owns, parsed.value, identities, upstream, audit, now);
  const response = yield* upstream.forwardOwned(result.owns, { request, template: "/v5/identities/{id}", operation: `identity.${request.method.toLowerCase()}` }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  if (request.method === "DELETE" && response.ok) yield* ownership.markDeleted(principal.tenantId, "identity", row.value.cmuxId, now).pipe(Effect.ignore);
  return copyResponse(response);
});

const identityPermission = <C, R extends ResourceId>(request: Request, parts: ReadonlyArray<string>, principal: Principal, identityProof: TenantOwnsResource<C, R>, identityId: IdentityId, ownership: OwnershipStoreService, identities: IdentityStoreService, upstream: CompatUpstreamService, audit: AuditStoreService, now: Date) => Effect.gen(function* () {
  if (request.method === "POST" && principal.resourceAllowlist !== null) return forbidden("A key limited to specific resources cannot grant identity access");
  if (parts.length === 0 && request.method === "GET") {
    const grants = yield* identities.listGrants(principal.tenantId, identityId);
    return Response.json({ permissions: grants.map((grant) => ({ id: grant.id, identityId: identityId, vmId: grant.upstreamId, allowedLinuxUsers: grant.allowedLinuxUsers, grantedAt: grant.grantedAt.toISOString(), grantedBy: grant.grantedBy })) });
  }
  const body = request.method === "POST" || request.method === "PATCH" ? yield* Effect.promise(() => parseRequestJson(request)) : null;
  const vmId = parts[0] ?? stringField(body, "vmId");
  if (vmId === undefined || vmId === null) return notFound();
  const resolvedVmId = vmId;
  const vmRow = yield* ownership.findByUpstream(principal.tenantId, "vm", resolvedVmId);
  if (Option.isNone(vmRow)) return notFound();
  const vmParsed = parseVmId(vmRow.value.cmuxId);
  if (Option.isNone(vmParsed)) return notFound();
  const vmOwns = yield* name(principal, (caller) => name(vmParsed.value, (vm) => tenantOwnsVm(caller, vm)));
  if (vmOwns === null) return notFound();
  const template = parts.length === 0 ? "/v5/identities/{id}/permissions/vm" : `/v5/identities/{id}/permissions/vm/${encodeURIComponent(resolvedVmId)}`;
  const response = yield* upstream.forwardOwned(identityProof, { request, template, operation: `identity.permission.${request.method.toLowerCase()}` }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  if (response.ok && request.method === "POST") {
    const data = yield* Effect.promise(() => parseJson(response));
    yield* identities.recordGrant({ id: stringField(data, "id") ?? idFrom("vmp-"), tenantId: principal.tenantId, identityCmuxId: identityId, vmCmuxId: vmParsed.value, upstreamId: vmRow.value.upstreamId, allowedLinuxUsers: Array.isArray(data?.allowedLinuxUsers) ? data.allowedLinuxUsers.filter((value): value is string => typeof value === "string") : null, grantedAt: now, grantedBy: principal.tenantId }).pipe(Effect.ignore);
  }
  if (response.ok && request.method === "DELETE") yield* identities.revokeGrant(principal.tenantId, identityId, vmParsed.value, now).pipe(Effect.ignore);
  yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: `v5.identity.permission.${request.method.toLowerCase()}`, cmuxId: identityId, outcome: response.ok ? "ok" : `HTTP_${response.status}`, at: now }).pipe(Effect.ignore);
  return copyResponse(response);
});

const identityToken = <C, R extends ResourceId>(request: Request, parts: ReadonlyArray<string>, principal: Principal, identityProof: TenantOwnsResource<C, R>, identityId: IdentityId, identities: IdentityStoreService, upstream: CompatUpstreamService, audit: AuditStoreService, now: Date) => Effect.gen(function* () {
  const tokenPath = parts[0] === undefined ? "/v5/identities/{id}/tokens" : `/v5/identities/{id}/tokens/${encodeURIComponent(parts[0])}`;
  const response = yield* upstream.forwardOwned(identityProof, { request, template: tokenPath, operation: `identity.token.${request.method.toLowerCase()}` }).pipe(Effect.mapError((failure) => providerError(failure.status)));
  if (response.ok && request.method === "POST") {
    const data = yield* Effect.promise(() => parseJson(response));
    const token = stringField(data, "token");
    const tokenId = stringField(data, "id");
    if (token !== null && tokenId !== null) yield* hash(token).pipe(Effect.flatMap((tokenHash) => identities.recordToken({ id: tokenId, tenantId: principal.tenantId, identityCmuxId: identityId, tokenHash, createdAt: now })), Effect.ignore);
  }
  if (response.ok && request.method === "DELETE" && parts[0] !== undefined) yield* identities.revokeToken(principal.tenantId, identityId, parts[0], now).pipe(Effect.ignore);
  yield* audit.append({ tenantId: principal.tenantId, actor: actorRef(principal.actor), ownerActor: null, action: `v5.identity.token.${request.method.toLowerCase()}`, cmuxId: identityId, outcome: response.ok ? "ok" : `HTTP_${response.status}`, at: now }).pipe(Effect.ignore);
  return copyResponse(response);
});

const identityExec = (request: Request, parts: ReadonlyArray<string>, token: string, upstream: CompatUpstreamService, ownership: OwnershipStoreService, identities: IdentityStoreService, audit: AuditStoreService, usage: { readonly record: (event: import("../metering/recorder.ts").UsageEvent) => Effect.Effect<void> }, now: Date) => Effect.gen(function* () {
  const tokenRow = yield* hash(token).pipe(Effect.flatMap((value) => identities.findToken(value)), Effect.orElseSucceed(() => Option.none()));
  if (Option.isNone(tokenRow)) return notFound();
  const vmRow = yield* ownership.findByUpstream(tokenRow.value.tenantId, "vm", parts[1] ?? "").pipe(Effect.orElseSucceed(() => Option.none()));
  if (Option.isNone(vmRow)) return notFound();
  const vm = parseVmId(vmRow.value.cmuxId);
  const identity = parseIdentityId(tokenRow.value.identityCmuxId);
  if (Option.isNone(vm) || Option.isNone(identity)) return notFound();
  const grant = yield* identities.findGrant(tokenRow.value.tenantId, identity.value, vm.value).pipe(Effect.orElseSucceed(() => Option.none()));
  if (Option.isNone(grant)) return notFound();
  const principal: Principal = { tenantId: tokenRow.value.tenantId, actor: { kind: "session", userId: UserId.make("identity") }, scopes: new Set(["vm:exec", "vm:terminal"]), resourceAllowlist: null, credentialExpiresAt: null };
  const response = yield* name(principal, (caller) => name(vm.value, (namedVm) => tenantOwnsVm(caller, namedVm).pipe(Effect.flatMap((owns) => owns === null ? Effect.succeed(notFound()) : upstream.forwardOwned(owns as unknown as TenantOwnsResource<never, ResourceId>, { request, template: `/v5/vms/{id}/${parts.slice(2).map(encodeURIComponent).join("/")}`, operation: "identity.exec", identityAccessToken: token }).pipe(Effect.map(copyResponse), Effect.mapError((failure) => providerError(failure.status)))))));
  yield* audit.append({ tenantId: principal.tenantId, actor: "identity-token", ownerActor: null, action: "v5.identity.exec", cmuxId: vmRow.value.cmuxId, outcome: response.ok ? "ok" : `HTTP_${response.status}`, at: now }).pipe(Effect.ignore);
  if (response.ok) yield* usage.record({ kind: "vm_woken_by_identity", tenantId: principal.tenantId, upstreamVmId: parts[1] ?? "", at: now }).pipe(Effect.ignore);
  return response;
});
