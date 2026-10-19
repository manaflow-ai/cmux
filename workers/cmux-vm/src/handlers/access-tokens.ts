import { HttpApiBuilder, HttpServerResponse } from "@effect/platform";
import { name } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { CreatedAccessToken, AccessTokenList, SshAccess, type CreateAccessTokenRequest } from "../access-tokens/api.ts";
import { AccessTokenStore, AccessTokens, type AccessTokenRecord, type AccessTokenScope } from "../access-tokens/tokens.ts";
import { AccessTokenId } from "../access-tokens/tokens.ts";
import { actorRef, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import { badRequest, Forbidden, NotFound, unavailable, missingScope } from "../errors.ts";
import { parseVmId, type VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { tenantOwnsVm } from "../proofs/tenant-owns-resource.ts";
import { mintAccessTokenAllows } from "../proofs/access-token-allows.ts";
import { UpstreamAccessTokens } from "../upstream/access-tokens.ts";
import { CmuxVmApi } from "../api.ts";
import { audited } from "./common.ts";

const managementScope = "access-token:create" as const;
const scopeSet = (scopes: ReadonlyArray<AccessTokenScope>) => new Set(scopes);

const view = (record: AccessTokenRecord) => ({
  id: record.id,
  principal: record.principal,
  vmIds: record.vmIds,
  scopes: record.scopes,
  linuxUser: record.linuxUser,
  createdBy: record.createdBy,
  createdAt: record.createdAt.toISOString(),
  expiresAt: record.expiresAt.toISOString(),
  revokedAt: record.revokedAt?.toISOString() ?? null,
});

const parseTokenId = (raw: string): AccessTokenId | null => {
  try {
    return AccessTokenId.make(raw);
  } catch {
    return null;
  }
};

const parseVm = (raw: string): VmId | null => {
  const parsed = parseVmId(raw);
  return Option.isSome(parsed) ? parsed.value : null;
};

const recordFor = (tenantId: Principal["tenantId"], raw: string) => {
  const id = parseTokenId(raw);
  return id === null ? Effect.succeed(null) : Effect.flatMap(AccessTokenStore, (store) => store.find(tenantId, id).pipe(Effect.mapError(() => unavailable())));
};

const tokenVmProof = (record: AccessTokenRecord) =>
  Effect.sync(() => {
    const synthetic: Principal = {
      tenantId: record.tenantId,
      actor: { kind: "access-token", tokenId: record.id, principal: record.principal },
      scopes: new Set(),
      resourceAllowlist: new Set(record.vmIds),
      credentialExpiresAt: record.expiresAt,
      accessTokenScopes: record.scopes,
      accessTokenLinuxUser: record.linuxUser,
    };
    return { synthetic };
  });

const create = (payload: CreateAccessTokenRequest) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    if (principal.actor.kind === "access-token") return yield* Effect.fail(new Forbidden({ message: "Access tokens cannot mint or manage access tokens" }));
    if (!principal.scopes.has(managementScope)) return yield* Effect.fail(missingScope(managementScope));
    const store = yield* AccessTokenStore;
    const signer = yield* AccessTokens;
    const now = new Date(yield* Clock.currentTimeMillis);
    const expiresAt = new Date(now.getTime() + (payload.ttlSeconds ?? 3600) * 1000);
    const vmIds = [...new Set(payload.vmIds)];
    if (vmIds.length !== payload.vmIds.length) return yield* Effect.fail(badRequest("vmIds must not contain duplicates"));
    const parsedVmIds = vmIds.map(parseVm);
    if (parsedVmIds.some((value) => value === null)) return yield* Effect.fail(new NotFound({ message: "VM not found" }));
    const ownedVmIds = parsedVmIds.filter((value): value is VmId => value !== null);
    const valid = yield* name(principal, (caller) => Effect.forEach(ownedVmIds, (vmId) => name(vmId, (vm) => tenantOwnsVm(caller, vm).pipe(Effect.map((proof) => proof !== null), Effect.mapError(() => unavailable())))));
    if (valid.some((ok) => !ok)) return yield* Effect.fail(new NotFound({ message: "VM not found" }));
    const created = yield* signer.mint({
      tenantId: principal.tenantId,
      principal: payload.principal,
      vmIds: ownedVmIds,
      scopes: payload.scopes,
      linuxUser: payload.linuxUser ?? "cmux",
      expiresAt,
    }).pipe(Effect.mapError(() => unavailable()));
    const record: AccessTokenRecord = {
      id: created.id,
      tenantId: principal.tenantId,
      principal: payload.principal,
      vmIds: ownedVmIds,
      scopes: payload.scopes,
      linuxUser: payload.linuxUser ?? "cmux",
      expiresAt,
      createdBy: actorRef(principal.actor),
      createdAt: now,
      revokedAt: null,
      providerIdentityId: null,
    };
    yield* store.insert(record).pipe(Effect.mapError(() => unavailable()));
    return new CreatedAccessToken({ id: created.id, token: created.token, expiresAt: expiresAt.toISOString() });
  });

const list = Effect.gen(function* () {
  const principal = yield* CurrentPrincipal;
  if (principal.actor.kind === "access-token") return yield* Effect.fail(new Forbidden({ message: "Access tokens cannot mint or manage access tokens" }));
  if (!principal.scopes.has(managementScope)) return yield* Effect.fail(missingScope(managementScope));
  const store = yield* AccessTokenStore;
  const records = yield* store.list(principal.tenantId, 100).pipe(Effect.mapError(() => unavailable()));
  return new AccessTokenList({ items: records.map(view) });
});

const revoke = (rawId: string) =>
  audited(
    "access-token.revoke",
    rawId,
    Effect.gen(function* () {
      const principal = yield* CurrentPrincipal;
      if (principal.actor.kind === "access-token") return yield* Effect.fail(new Forbidden({ message: "Access tokens cannot mint or manage access tokens" }));
      if (!principal.scopes.has(managementScope)) return yield* Effect.fail(missingScope(managementScope));
      const id = parseTokenId(rawId);
      if (id === null) return yield* Effect.fail(new NotFound({ message: "Access token not found" }));
      const store = yield* AccessTokenStore;
      const at = new Date(yield* Clock.currentTimeMillis);
      const record = yield* store.revoke(principal.tenantId, id, at).pipe(Effect.mapError(() => unavailable()));
      if (record === null) return yield* Effect.fail(new NotFound({ message: "Access token not found" }));
      const limits = yield* TenantLimits;
      yield* limits.revokeAccessToken(principal.tenantId, record.id, record.expiresAt.getTime()).pipe(Effect.mapError(() => unavailable()));
      if (record.providerIdentityId !== null) {
        const upstream = yield* UpstreamAccessTokens;
        yield* upstream.revokeIdentity(record.providerIdentityId).pipe(Effect.ignore);
      }
      return HttpServerResponse.empty({ status: 204 });
    }),
  );

const ssh = (rawId: string) =>
  audited(
    "access-token.ssh",
    rawId,
    Effect.gen(function* () {
      const principal = yield* CurrentPrincipal;
      if (principal.actor.kind === "access-token") return yield* Effect.fail(new Forbidden({ message: "Access tokens cannot mint delegated credentials" }));
      if (!principal.scopes.has(managementScope)) return yield* Effect.fail(missingScope(managementScope));
      const record = yield* recordFor(principal.tenantId, rawId);
      if (record === null) return yield* Effect.fail(new NotFound({ message: "Access token not found" }));
      const now = new Date(yield* Clock.currentTimeMillis);
      if (record.revokedAt !== null || record.expiresAt <= now) return yield* Effect.fail(new NotFound({ message: "Access token not found" }));
      if (!scopeSet(record.scopes).has("ssh")) return yield* Effect.fail(new Forbidden({ message: "This access token lacks the ssh scope", missingScope: undefined }));
      const vmRaw = record.vmIds[0];
      if (vmRaw === undefined) return yield* Effect.fail(new NotFound({ message: "VM not found" }));
      const parsed = parseVm(vmRaw);
      if (parsed === null) return yield* Effect.fail(new NotFound({ message: "VM not found" }));
      const { synthetic } = yield* tokenVmProof(record);
      const upstream = yield* UpstreamAccessTokens;
      const delegated = yield* name(synthetic, <C>(caller: import("@gdp-ts/core").Named<C, Principal>) =>
        name(parsed, <V>(vm: import("@gdp-ts/core").Named<V, import("../lib/ids.ts").VmId>) =>
          Effect.flatMap(tenantOwnsVm(caller, vm), (owns): Effect.Effect<import("../upstream/access-tokens.ts").DelegatedSsh, NotFound | import("../upstream/client.ts").UpstreamError> =>
            owns === null
              ? Effect.fail(new NotFound({ message: "VM not found" }))
              : upstream.mintSsh(vm, { owns, allows: mintAccessTokenAllows(caller, record.id, record.tenantId, record.principal, record.vmIds) }, record.linuxUser),
          ),
        ),
      ).pipe(Effect.mapError((error) => error instanceof NotFound ? error : unavailable()));
      yield* (yield* AccessTokenStore).setProviderIdentity(principal.tenantId, record.id, delegated.identityId).pipe(Effect.mapError(() => unavailable()));
      return new SshAccess({ host: delegated.host, user: delegated.user, password: delegated.password });
    }),
  );

export const accessTokensHandlers = HttpApiBuilder.group(CmuxVmApi, "accessTokens", (handlers) =>
  handlers
    .handle("createAccessToken", ({ payload }) => create(payload))
    .handle("listAccessTokens", () => list)
    .handle("revokeAccessToken", ({ path }) => revoke(path.tokenId))
    .handle("mintAccessTokenSsh", ({ path }) => ssh(path.tokenId)),
);
