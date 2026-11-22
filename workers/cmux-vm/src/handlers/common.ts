/**
 * Steps every VM handler shares: prove a scope, apply the tenant's rate limit,
 * resolve a public VM id through the ownership table, and audit mutations.
 *
 * Order matters and is the same everywhere: scope first (a 403 never depends
 * on which resource was asked for), then the rate limit (which counts only the
 * caller's own tenant), then ownership (another tenant's resource is 404).
 */
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { AuditStore } from "../db/stores.ts";
import { auditActorOf, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import type { Scope } from "../domain/scopes.ts";
import { missingScope, QuotaExceeded, unavailable, vmNotFound, type ServiceUnavailable } from "../errors.ts";
import { parseVmId, type VmId } from "../lib/ids.ts";
import type { RateClass } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import { TenantPolicy } from "../policy.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsVm, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";

/** Logs which dependency failed (an operation name only, never ids or causes) and answers 503. */
export const dependencyDown =
  (operation: string) =>
  (_error: unknown): Effect.Effect<never, ServiceUnavailable> =>
    Effect.logWarning("cmux-vm dependency unavailable").pipe(
      Effect.annotateLogs({ operation }),
      Effect.zipRight(Effect.fail(unavailable())),
    );

/** Spends one request from the tenant's per-minute budget for `rateClass`, or fails with 429. */
export const rateLimit = (principal: Principal, rateClass: RateClass) =>
  Effect.gen(function* () {
    const policy = yield* TenantPolicy;
    const limits = yield* TenantLimits;
    const decision = yield* limits
      .rate(principal.tenantId, rateClass, policy.rate(rateClass))
      .pipe(Effect.catchAll(dependencyDown("limits.rate")));
    if (!decision.ok) {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: "Too many requests for this team; retry later",
          retryAfterSeconds: decision.retryAfterSeconds,
          budget: "rate",
        }),
      );
    }
  });

/**
 * Proves `scope` for the caller and applies the rate limit, then runs `k`
 * with the named caller and the proof. For tenant-wide endpoints.
 */
export const withCaller = <const S extends Scope, A, E, R>(
  scope: S,
  rateClass: RateClass,
  k: <C>(caller: Named<C, Principal>, granted: KeyHasScope<C, S>) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    return yield* name(principal, (caller) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        yield* rateLimit(principal, rateClass);
        return yield* k(caller, granted);
      }),
    );
  });

/**
 * Resolves a public VM id for the caller: proves `scope`, applies the rate
 * limit, proves the caller's tenant owns the VM, then runs `k` with the proofs.
 */
export const withOwnedVm = <const S extends Scope, A, E, R>(
  rawId: string,
  scope: S,
  rateClass: RateClass,
  k: <C, V>(
    caller: Named<C, Principal>,
    vm: Named<V, VmId>,
    proofs: { readonly owns: TenantOwnsResource<C, V>; readonly scope: KeyHasScope<C, S> },
  ) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    return yield* name(principal, rawId, (caller, raw) =>
      Effect.gen(function* () {
        const granted = keyHasScope(caller, scope);
        if (granted === null) return yield* Effect.fail(missingScope(scope));
        yield* rateLimit(principal, rateClass);
        const parsed = parseVmId(raw.value);
        if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
        return yield* name(parsed.value, (vm) =>
          Effect.gen(function* () {
            const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")));
            if (owns === null) return yield* Effect.fail(vmNotFound());
            return yield* k(caller, vm, { owns, scope: granted });
          }),
        );
      }),
    );
  });

/** The public tag of a failure, for the audit log. */
const outcomeOf = (error: unknown): string =>
  typeof error === "object" && error !== null && "_tag" in error && typeof error._tag === "string" && /^[A-Za-z]{1,64}$/u.test(error._tag)
    ? error._tag
    : "Error";

/**
 * Writes one audit row for a mutation: tenant, actor (user, key or device id;
 * a device also names the owner it acted for), action,
 * the public id it produced or acted on, and its outcome. Never request
 * bodies. If the audit table cannot be written, the row goes to the Worker
 * log instead and the request is not failed for it.
 */
export const audited = <A, E, R>(
  action: string,
  targetId: string | null,
  effect: Effect.Effect<A, E, R>,
  producedId?: (result: A) => string | null,
  failedId?: (error: E) => string | null,
) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    const store = yield* AuditStore;
    const write = (cmuxId: string | null, outcome: string) =>
      Effect.gen(function* () {
        const at = new Date(yield* Clock.currentTimeMillis);
        const entry = { tenantId: principal.tenantId, ...auditActorOf(principal), action, cmuxId, outcome, at };
        yield* store.append(entry).pipe(
          Effect.catchAll(() =>
            Effect.sync(() => console.error(JSON.stringify({ event: "cmux_vm_audit_fallback", ...entry, at: at.toISOString() }))),
          ),
        );
      });
    return yield* effect.pipe(
      Effect.tap((result) => write(producedId === undefined ? targetId : (producedId(result) ?? targetId), "ok")),
      Effect.tapError((error) => write(failedId === undefined ? targetId : (failedId(error) ?? targetId), outcomeOf(error))),
    );
  });

/** The cmux id in a request path, when it is a well-formed VM id; audit rows never carry free text. */
export const auditableVmId = (raw: string): string | null => (Option.isSome(parseVmId(raw)) ? raw : null);
