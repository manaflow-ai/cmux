/**
 * Client session identities (src/api/client-sessions.ts, cx-b4h.6).
 *
 * Every per-session route resolves the VM through withOwnedVm (scope, rate
 * limit, ownership: another tenant's or agent's VM is 404 before anything
 * else), then the session by (tenant, VM, id) from cmux's own table: a session
 * is reachable only through the VM it was minted for, and a revoked one is
 * 404. The provider identity id stays server-side; token ids are cmux ids.
 */
import { HttpApiBuilder } from "@effect/platform";
import { Clock, Effect, Option } from "effect";
import { CmuxVmApi } from "../api.ts";
import { ClientSessionSummary } from "../api/agents.ts";
import { ClientSessionPage, ClientSessionToken, ClientSessionTokenList, ClientSessionTokenSummary } from "../api/client-sessions.ts";
import { AgentStore, type ClientSessionRow } from "../db/agents.ts";
import { carriesRequiredLabels } from "../domain/principal.ts";
import { NotFound, unavailable } from "../errors.ts";
import { parseClientSessionId, parseClientSessionTokenId, TenantId, type VmId } from "../lib/ids.ts";
import { UpstreamClient, type UpstreamError } from "../upstream/client.ts";
import { audited, auditableVmId, withCaller, withOwnedVm } from "./common.ts";

const sessionNotFound = () => new NotFound({ message: "Client session not found" });
const tokenNotFound = () => new NotFound({ message: "Client session token not found" });

/** A provider 404 means the VM or identity is gone under us: the caller sees "not found", anything else is 503. */
const upstreamFailure = (error: UpstreamError) => (error.status === 404 ? sessionNotFound() : unavailable());

const summaryOf = (row: ClientSessionRow, linuxUser: string = row.linuxUser) =>
  new ClientSessionSummary({ id: row.id, vmId: row.vmId, linuxUser, createdAt: row.createdAt.toISOString() });

/** The live session `rawId` of this VM in the caller's tenant, or 404. */
const liveSession = (tenantId: string, vmId: VmId, rawId: string) =>
  Effect.gen(function* () {
    const parsed = parseClientSessionId(rawId);
    if (Option.isNone(parsed)) return yield* Effect.fail(sessionNotFound());
    const agents = yield* AgentStore;
    const row = yield* agents.findClientSession(TenantId.make(tenantId), vmId, parsed.value).pipe(Effect.mapError(() => unavailable()));
    if (row === null || row.revokedAt !== null) return yield* Effect.fail(sessionNotFound());
    return row;
  });

const DEFAULT_LIMIT = 100;

export const clientSessionsHandlers = HttpApiBuilder.group(CmuxVmApi, "clientSessions", (handlers) =>
  handlers
    .handle("listTenantClientSessions", ({ urlParams }) =>
      withCaller("vm:exec", "exec", (caller) =>
        Effect.gen(function* () {
          const principal = caller.value;
          const agents = yield* AgentStore;
          const limit = urlParams.limit ?? DEFAULT_LIMIT;
          const rows = yield* agents
            .liveTenantClientSessions(TenantId.make(principal.tenantId), urlParams.cursor ?? null, limit)
            .pipe(Effect.mapError(() => unavailable()));
          // The same reach rules as one VM's ownership check: the key's resource allowlist and a service or agent key's labels.
          const visible = rows.filter(
            (row) => (principal.resourceAllowlist === null || principal.resourceAllowlist.has(row.vmId)) && carriesRequiredLabels(principal, row.vmLabels),
          );
          const last = rows.at(-1);
          return new ClientSessionPage({
            sessions: visible.map((row) => summaryOf(row)),
            nextCursor: rows.length === limit && last !== undefined ? last.id : null,
          });
        }),
      ),
    )
    .handle("getClientSession", ({ path }) =>
      withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm) =>
        Effect.map(liveSession(caller.value.tenantId, vm.value, path.sessionId), (row) => summaryOf(row)),
      ),
    )
    .handle("setClientSessionLinuxUser", ({ path, payload }) =>
      audited(
        "vm.client_session_linux_user",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm, proofs) =>
          Effect.gen(function* () {
            const row = yield* liveSession(caller.value.tenantId, vm.value, path.sessionId);
            const upstream = yield* UpstreamClient;
            const agents = yield* AgentStore;
            yield* upstream.setClientSessionLinuxUser(vm, proofs, row.upstreamIdentityId, payload.linuxUser).pipe(Effect.mapError(upstreamFailure));
            yield* agents
              .setClientSessionLinuxUser(TenantId.make(caller.value.tenantId), row.id, payload.linuxUser)
              .pipe(Effect.mapError(() => unavailable()));
            return summaryOf(row, payload.linuxUser);
          }),
        ),
      ),
    )
    .handle("listClientSessionTokens", ({ path }) =>
      withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm, proofs) =>
        Effect.gen(function* () {
          const row = yield* liveSession(caller.value.tenantId, vm.value, path.sessionId);
          const upstream = yield* UpstreamClient;
          const ids = yield* upstream.listClientSessionTokens(vm, proofs, row.upstreamIdentityId).pipe(Effect.mapError(upstreamFailure));
          return new ClientSessionTokenList({ tokens: ids.map((id) => new ClientSessionTokenSummary({ id, sessionId: row.id })) });
        }),
      ),
    )
    .handle("createClientSessionToken", ({ path }) =>
      audited(
        "vm.client_session_token",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm, proofs) =>
          Effect.gen(function* () {
            const row = yield* liveSession(caller.value.tenantId, vm.value, path.sessionId);
            const upstream = yield* UpstreamClient;
            const grant = yield* upstream.mintClientSessionToken(vm, proofs, row.upstreamIdentityId).pipe(Effect.mapError(upstreamFailure));
            const createdAt = new Date(yield* Clock.currentTimeMillis);
            return new ClientSessionToken({
              id: grant.tokenId,
              sessionId: row.id,
              vmId: vm.value,
              token: grant.token,
              providerVmId: grant.providerVmId,
              linuxUser: row.linuxUser,
              apiBaseUrl: grant.apiBaseUrl,
              ssh: { host: grant.sshHost, user: `${grant.providerVmId}+${row.linuxUser}` },
              createdAt: createdAt.toISOString(),
            });
          }),
        ),
      ),
    )
    .handle("revokeClientSessionToken", ({ path }) =>
      audited(
        "vm.client_session_token_revoke",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm, proofs) =>
          Effect.gen(function* () {
            const row = yield* liveSession(caller.value.tenantId, vm.value, path.sessionId);
            const tokenId = parseClientSessionTokenId(path.tokenId);
            if (Option.isNone(tokenId)) return yield* Effect.fail(tokenNotFound());
            const upstream = yield* UpstreamClient;
            yield* upstream.revokeClientSessionToken(vm, proofs, row.upstreamIdentityId, tokenId.value).pipe(Effect.mapError(upstreamFailure));
          }),
        ),
      ),
    ),
);
