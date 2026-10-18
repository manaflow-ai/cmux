/** The tenant ledger keeps digests and public VM ids, never request bodies. */
import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import { conflict, unavailable } from "../errors.ts";
import type { IdempotencyProgress } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import { OwnershipStore } from "../db/stores.ts";

const fingerprint = (value: unknown) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/** Replays a completed mutation or resumes a fork from its retained snapshot. */
export const idempotent = <A extends { readonly id: string }, E, R, ER, RR>(
  principal: Principal,
  key: string | undefined,
  request: unknown,
  run: (resumeFrom: IdempotencyProgress | null, keyed: string | null) => Effect.Effect<A, E, R>,
  replay: (vmId: string) => Effect.Effect<A, ER, RR>,
) => Effect.gen(function* () {
  if (key === undefined) return yield* run(null, null);
  const limits = yield* TenantLimits;
  const scoped = `${yield* fingerprint(principal.actor.kind === "service" ? ["service", principal.actor.serviceId, key] : ["key", key])}`;
  const claim = yield* limits.begin(principal.tenantId, scoped, yield* fingerprint(request)).pipe(Effect.mapError(() => unavailable()));
  switch (claim.state) {
    case "mismatch":
      return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
    case "in_progress":
      if (claim.progress?.phase === "creating") {
        // An ownership commit can outlive a failed completion/abandon RPC. SQL may settle it,
        // but an active claim with no ownership row never permits another provider operation.
        const status = yield* (yield* OwnershipStore).allocationStatus(principal.tenantId, claim.progress.vmId).pipe(Effect.mapError(() => unavailable()));
        if (status !== "absent") {
          yield* limits.advance(principal.tenantId, scoped, { phase: "done", vmId: claim.progress.vmId }).pipe(Effect.mapError(() => unavailable()));
          return yield* replay(claim.progress.vmId);
        }
      }
      return yield* Effect.fail(conflict("A request with this Idempotency-Key is still running; retry shortly"));
    case "resume":
      if (claim.progress.phase === "done") return yield* replay(claim.progress.vmId);
      break;
    case "new":
      break;
  }
  const resumeFrom = claim.state === "resume" ? claim.progress : null;
  return yield* run(resumeFrom, scoped).pipe(
    Effect.tap((vm) => limits.advance(principal.tenantId, scoped, { phase: "done", vmId: vm.id }).pipe(Effect.mapError(() => unavailable()))),
    Effect.tapError(() => limits.abandon(principal.tenantId, scoped)),
  );
});
