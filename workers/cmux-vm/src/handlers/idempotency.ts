/** The tenant ledger keeps digests and public VM ids, never request bodies. */
import { Effect } from "effect";
import type { GeneratedCreation } from "../domain/generated-creation.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import type { Principal } from "../domain/principal.ts";
import { conflict, unavailable } from "../errors.ts";
import type { IdempotencyProgress } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import { OwnershipStore } from "../db/stores.ts";

export const requestFingerprint = (value: unknown) =>
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
  clientFingerprint?: string,
  generated?: GeneratedCreation,
) => Effect.gen(function* () {
  if (key === undefined) return yield* run(null, null);
  const limits = yield* TenantLimits;
  const scoped = yield* scopedCreationKey(principal, key);
  const claim = yield* limits.begin(principal.tenantId, scoped, yield* requestFingerprint(request), clientFingerprint, generated).pipe(Effect.mapError(() => unavailable()));
  if (claim.state === "resume" && (claim.progress.phase === "cancelled" || (claim.progress.phase === "creating" && claim.progress.cancelRequested === true))) {
    return yield* Effect.fail(conflict("This VM creation was cancelled; inspect its status"));
  }
  switch (claim.state) {
    case "mismatch":
      return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
    case "in_progress":
      if (claim.progress?.phase === "creating") {
        // An ownership commit can outlive a failed completion/abandon RPC. SQL may settle it,
        // but an active claim with no committed row never permits another provider operation.
        const status = yield* (yield* OwnershipStore).allocationStatus(principal.tenantId, claim.progress.vmId).pipe(Effect.mapError(() => unavailable()));
        if (status === "live" || status === "deleted") {
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
