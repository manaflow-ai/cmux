/**
 * The agent reaper: deletes the VMs of agent keys that expired or were
 * revoked, with their client sessions, and revokes client sessions whose VM
 * was deleted while their revoke failed. The Worker's cron runs it every few
 * minutes; revoking an agent key also runs its cleanup at once.
 *
 * It acts as the service actor `agent-reaper`, confined to exactly the expired
 * key's labels, through the same delete path (ownership proof, tombstone,
 * creation settlement, audit row) as a caller's DELETE /v1/vms/{vmId}. A key
 * is marked cleaned only when none of its VMs is left.
 */
import { name } from "@gdp-ts/core";
import { Clock, Effect, Either } from "effect";
import { AgentStore, type AgentKeyRow } from "../db/agents.ts";
import { CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { revokeVmClientSessions } from "../handlers/agent-sandboxes.ts";
import { deleteVmById } from "../handlers/vms.ts";
import { visitOwnedVms } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../upstream/client.ts";

export const REAPER_ACTOR = "agent-reaper";
/** VMs one key's cleanup visits per run; a key with more is finished by later runs. */
const VMS_PER_KEY = 100;
const KEYS_PER_RUN = 50;
const ORPHANS_PER_RUN = 100;

export interface ReapReport {
  /** Agent keys visited this run (expired or revoked, not yet cleaned). */
  readonly agentKeys: number;
  readonly vmsDeleted: number;
  readonly identitiesRevoked: number;
  /** VM deletes and identity revokes that failed; they are retried next run. */
  readonly failures: number;
}

const REAPER_SCOPES: ReadonlySet<Scope> = new Set<Scope>(["vm:read", "vm:write"]);

/** Deletes one agent key's VMs (revoking their client sessions first). `done` when none is left. */
export const cleanupAgentKey = (row: AgentKeyRow) => {
  const principal: Principal = {
    tenantId: row.tenantId,
    actor: { kind: "service", serviceId: REAPER_ACTOR },
    scopes: REAPER_SCOPES,
    resourceAllowlist: null,
    credentialExpiresAt: null,
    requiredLabels: row.labels,
  };
  return Effect.gen(function* () {
    const page = yield* name(principal, (caller) =>
      visitOwnedVms(caller, { limit: VMS_PER_KEY, after: null, labels: null }, (vm) => Effect.succeed(vm.value)),
    );
    let vmsDeleted = 0;
    let identitiesRevoked = 0;
    let failures = 0;
    for (const vmId of page.results) {
      const outcome = yield* Effect.either(
        Effect.gen(function* () {
          identitiesRevoked += yield* revokeVmClientSessions(row.tenantId, vmId);
          yield* deleteVmById(vmId);
        }),
      );
      if (Either.isRight(outcome)) vmsDeleted += 1;
      else failures += 1;
    }
    return { vmsDeleted, identitiesRevoked, failures, done: failures === 0 && page.fetched < VMS_PER_KEY };
  }).pipe(Effect.provideService(CurrentPrincipal, principal));
};

export const runAgentReaper = Effect.gen(function* () {
  const agents = yield* AgentStore;
  const upstream = yield* UpstreamClient;
  const now = new Date(yield* Clock.currentTimeMillis);
  const due = yield* agents.dueAgentKeys(now, KEYS_PER_RUN);
  let vmsDeleted = 0;
  let identitiesRevoked = 0;
  let failures = 0;
  for (const row of due) {
    const outcome = yield* Effect.either(cleanupAgentKey(row));
    if (Either.isLeft(outcome)) {
      failures += 1;
      continue;
    }
    vmsDeleted += outcome.right.vmsDeleted;
    identitiesRevoked += outcome.right.identitiesRevoked;
    failures += outcome.right.failures;
    if (outcome.right.done) yield* agents.markAgentCleaned(row.tenantId, row.id, now).pipe(Effect.ignore);
  }
  const orphans = yield* agents.orphanClientSessions(ORPHANS_PER_RUN);
  for (const session of orphans) {
    const outcome = yield* Effect.either(
      upstream.deleteIdentity(session.upstreamIdentityId).pipe(
        Effect.zipRight(agents.markClientSessionRevoked(session.tenantId, session.id, now)),
      ),
    );
    if (Either.isRight(outcome)) identitiesRevoked += 1;
    else failures += 1;
  }
  const report: ReapReport = { agentKeys: due.length, vmsDeleted, identitiesRevoked, failures };
  if (due.length > 0 || orphans.length > 0) {
    yield* Effect.logInfo("cmux-vm agent reaper").pipe(Effect.annotateLogs({ ...report }));
  }
  return report;
});
