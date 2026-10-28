/**
 * Agent keys and per-VM client sessions (src/api/agents.ts).
 *
 * Issuing: a credential with vm:write that is not itself an agent key or
 * resource-allowlisted. The new key holds a subset of the issuer's scopes
 * within AGENT_SCOPES, never outlives the issuer, and is confined to
 * cmux.agent=<its id> plus the issuer's own required labels (a service key's
 * role=chief stays in force).
 *
 * Revoking: the issuer, an admin key or team admin, or the agent key itself.
 * Revoking deletes the agent's VMs at once, best effort; the reaper finishes.
 */
import { HttpApiBuilder } from "@effect/platform";
import { Clock, Effect, Option } from "effect";
import { CmuxVmApi } from "../api.ts";
import { ClientSession, ClientSessionList, ClientSessionSummary, CreatedAgentKey } from "../api/agents.ts";
import { generateApiKey, hashApiKey } from "../auth/credentials.ts";
import { TeamAdmin } from "../auth/team-admin.ts";
import { AgentStore } from "../db/agents.ts";
import { ApiKeyAdminStore } from "../db/api-keys.ts";
import { AGENT_DEFAULTS, AGENT_LABEL, AGENT_SCOPES, DEFAULT_LINUX_USER } from "../domain/agents.ts";
import { actorRef, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import { Forbidden, NotFound, unavailable, vmNotFound } from "../errors.ts";
import { ApiKeyId, newApiKeyId, newClientSessionId, parseClientSessionId, TenantId } from "../lib/ids.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { cleanupAgentKey } from "../agents/reaper.ts";
import { audited, auditableVmId, rateLimit, withCaller, withOwnedVm } from "./common.ts";
import { Schema } from "effect";

const parseKeyId = Schema.decodeUnknownOption(ApiKeyId);
const keyNotFound = () => new NotFound({ message: "Agent key not found" });
const sessionNotFound = () => new NotFound({ message: "Client session not found" });

/** Who may revoke an agent key: the key itself, its issuer, or a team admin (admin key or team-admin session). */
const mayRevoke = (principal: Principal, keyId: ApiKeyId, createdBy: string) =>
  Effect.gen(function* () {
    if (principal.actor.kind === "api_key" && principal.actor.keyId === keyId) return true;
    if (actorRef(principal.actor) === createdBy) return true;
    if (principal.scopes.has("admin")) return true;
    if (principal.actor.kind !== "session") return false;
    const teamAdmin = yield* TeamAdmin;
    return yield* teamAdmin.isAdmin(principal.tenantId, principal.actor.userId).pipe(Effect.mapError(() => unavailable()));
  });

export const agentsHandlers = HttpApiBuilder.group(CmuxVmApi, "agents", (handlers) =>
  handlers
    .handle("createAgentKey", ({ payload }) =>
      withCaller("vm:write", "write", (caller) =>
        Effect.gen(function* () {
          const issuer = caller.value;
          if (issuer.agent !== undefined) {
            return yield* Effect.fail(new Forbidden({ message: "An agent key cannot issue agent keys" }));
          }
          if (issuer.resourceAllowlist !== null) {
            return yield* Effect.fail(new Forbidden({ message: "A key limited to specific resources cannot issue agent keys" }));
          }
          // Without a request, the agent gets every agent scope the issuer holds.
          const scopes = [...new Set(payload.scopes ?? AGENT_SCOPES.filter((scope) => issuer.scopes.has(scope)))];
          const missing = scopes.find((scope) => !issuer.scopes.has(scope));
          if (missing !== undefined) {
            return yield* Effect.fail(new Forbidden({ message: `This credential cannot grant the ${missing} scope`, missingScope: missing }));
          }
          const now = new Date(yield* Clock.currentTimeMillis);
          const ttlSeconds = payload.ttlSeconds ?? AGENT_DEFAULTS.ttlSeconds;
          // An agent key never outlives its issuer: it ends at the earlier of its TTL and the issuer's expiry.
          const wanted = now.getTime() + ttlSeconds * 1000;
          const ceiling = issuer.credentialExpiresAt?.getTime() ?? Number.POSITIVE_INFINITY;
          const expiresAt = new Date(Math.min(wanted, ceiling));
          if (expiresAt.getTime() <= now.getTime()) {
            return yield* Effect.fail(new Forbidden({ message: "This credential has expired" }));
          }
          const id = newApiKeyId();
          const secret = generateApiKey();
          const keyHash = yield* hashApiKey(secret);
          const labels = { ...issuer.requiredLabels, [AGENT_LABEL]: id };
          const maxVms = payload.maxVms ?? AGENT_DEFAULTS.maxVms;
          const maxUsdPerHour = payload.maxUsdPerHour ?? AGENT_DEFAULTS.maxUsdPerHour;
          const store = yield* ApiKeyAdminStore;
          return yield* audited(
            "agentkey.create",
            null,
            store
              .insert({
                id,
                tenantId: issuer.tenantId,
                name: payload.name,
                keyHash,
                scopes,
                resourceAllowlist: null,
                createdBy: actorRef(issuer.actor),
                createdAt: now,
                expiresAt,
                agent: { labels, maxVms, maxUsdPerHour },
              })
              .pipe(
                Effect.mapError(() => unavailable()),
                Effect.as(
                  new CreatedAgentKey({
                    id,
                    name: payload.name,
                    key: secret,
                    scopes,
                    labels,
                    createdAt: now.toISOString(),
                    expiresAt: expiresAt.toISOString(),
                    maxVms,
                    maxUsdPerHour,
                  }),
                ),
              ),
            (created) => created.id,
          );
        }),
      ),
    )
    .handle("revokeAgentKey", ({ path }) =>
      Effect.gen(function* () {
        const principal = yield* CurrentPrincipal;
        yield* rateLimit(principal, "write");
        const parsed = parseKeyId(path.keyId);
        if (Option.isNone(parsed)) return yield* Effect.fail(keyNotFound());
        const keyId = parsed.value;
        const agents = yield* AgentStore;
        yield* audited(
          "agentkey.revoke",
          keyId,
          Effect.gen(function* () {
            const row = yield* agents.findAgentKey(principal.tenantId, keyId).pipe(Effect.mapError(() => unavailable()));
            if (row === null || !(yield* mayRevoke(principal, keyId, row.createdBy))) return yield* Effect.fail(keyNotFound());
            const now = new Date(yield* Clock.currentTimeMillis);
            yield* agents.revokeAgentKey(principal.tenantId, keyId, now).pipe(Effect.mapError(() => unavailable()));
            // Best effort now; whatever is left (a failed delete, a lost response) the reaper finishes.
            yield* cleanupAgentKey({ ...row, revokedAt: row.revokedAt ?? now }).pipe(Effect.ignore);
          }),
        );
      }),
    )
    .handle("createClientSession", ({ path, payload }) =>
      audited(
        "vm.client_session",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const agents = yield* AgentStore;
            const linuxUser = payload.linuxUser ?? DEFAULT_LINUX_USER;
            const grant = yield* upstream
              .openClientSession(vm, proofs, linuxUser)
              .pipe(Effect.mapError((error) => (error.status === 404 ? vmNotFound() : unavailable())));
            const id = newClientSessionId();
            const createdAt = new Date(yield* Clock.currentTimeMillis);
            yield* agents
              .insertClientSession({
                id,
                tenantId: TenantId.make(caller.value.tenantId),
                vmId: vm.value,
                upstreamIdentityId: grant.upstreamIdentityId,
                linuxUser,
                createdBy: actorRef(caller.value.actor),
                createdAt,
                revokedAt: null,
              })
              .pipe(
                // An unrecorded identity could never be revoked: delete it before answering.
                Effect.tapError(() => upstream.deleteIdentity(grant.upstreamIdentityId).pipe(Effect.ignore)),
                Effect.mapError(() => unavailable()),
              );
            return new ClientSession({
              id,
              vmId: vm.value,
              token: grant.token,
              providerVmId: grant.providerVmId,
              linuxUser,
              apiBaseUrl: grant.apiBaseUrl,
              ssh: { host: grant.sshHost, user: `${grant.providerVmId}+${linuxUser}` },
              createdAt: createdAt.toISOString(),
            });
          }),
        ),
      ),
    )
    .handle("listClientSessions", ({ path }) =>
      withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm) =>
        Effect.gen(function* () {
          const agents = yield* AgentStore;
          const rows = yield* agents.liveClientSessions(TenantId.make(caller.value.tenantId), vm.value).pipe(Effect.mapError(() => unavailable()));
          return new ClientSessionList({
            sessions: rows.map((row) => new ClientSessionSummary({ id: row.id, vmId: vm.value, linuxUser: row.linuxUser, createdAt: row.createdAt.toISOString() })),
          });
        }),
      ),
    )
    .handle("revokeClientSession", ({ path }) =>
      audited(
        "vm.client_session_revoke",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:exec", "exec", (caller, vm) =>
          Effect.gen(function* () {
            const parsed = parseClientSessionId(path.sessionId);
            if (Option.isNone(parsed)) return yield* Effect.fail(sessionNotFound());
            const agents = yield* AgentStore;
            const upstream = yield* UpstreamClient;
            const tenantId = TenantId.make(caller.value.tenantId);
            const row = yield* agents.findClientSession(tenantId, vm.value, parsed.value).pipe(Effect.mapError(() => unavailable()));
            if (row === null) return yield* Effect.fail(sessionNotFound());
            if (row.revokedAt !== null) return;
            yield* upstream.deleteIdentity(row.upstreamIdentityId).pipe(Effect.mapError(() => unavailable()));
            const at = new Date(yield* Clock.currentTimeMillis);
            yield* agents.markClientSessionRevoked(tenantId, row.id, at).pipe(Effect.mapError(() => unavailable()));
          }),
        ),
      ),
    ),
);
