/**
 * Steps every VM handler shares: prove a scope, apply the tenant's rate limit,
 * resolve a public VM id through the ownership table, and audit mutations.
 *
 * Order matters and is the same everywhere: scope first (a 403 never depends
 * on which resource was asked for), then the rate limit (which counts only the
 * caller's own tenant), then ownership (another tenant's resource is 404).
 * withOwnedVm reads the rate limit and ownership at once but answers in that order.
 */
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Either, Option } from "effect";
import { afterResponse } from "../db/sql.ts";
import { timedStep } from "../upstream/timing.ts";
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

/**
 * A fixed word for why a dependency call threw, never its message or any id: Cloudflare marks a Durable Object call that
 * hit a full input queue `overloaded` and one it may repeat `retryable`; the rest are told by the platform's own phrases.
 * 2026-11-28: every `limits.rate` 503 read the same ("dependency unavailable"), so a tenant object that was overloaded
 * could not be told from one that was down.
 */
export const failureClass = (error: unknown): string => {
  const e: unknown = error !== null && typeof error === "object" && "cause" in error ? error.cause : error;
  if (e === null || e === undefined || typeof e !== "object") return "unknown";
  if ("overloaded" in e && e.overloaded === true) return "overloaded";
  const text = "message" in e && typeof e.message === "string" ? e.message.toLowerCase() : "";
  for (const [needle, word] of [
    ["overloaded", "overloaded"],
    ["exceeded its memory", "memory_limit"],
    ["exceeded cpu", "cpu_limit"],
    ["network connection lost", "connection_lost"],
    ["object reset", "object_reset"],
    ["timed out", "timeout"],
    ["not confirmed", "write_unconfirmed"],
  ] as const)
    if (text.includes(needle)) return word;
  return "retryable" in e && e.retryable === true ? "retryable" : "other";
};

/** A Durable Object call Cloudflare says may be repeated, and that did not fail for want of capacity. */
export const isRepeatable = (error: unknown): boolean => {
  const c = failureClass(error);
  return c === "retryable" || c === "connection_lost" || c === "object_reset";
};

/** Logs which dependency failed (an operation name and a fixed cause word, never ids or messages) and answers 503. */
export const dependencyDown =
  (operation: string) =>
  (error: unknown): Effect.Effect<never, ServiceUnavailable> =>
    Effect.logWarning("cmux-vm dependency unavailable").pipe(
      Effect.annotateLogs({ operation, cause_class: failureClass(error) }),
      Effect.zipRight(Effect.fail(unavailable(operation))),
    );

/** Spends one request from the tenant's per-minute budget for `rateClass`, or fails with 429. */
export const rateLimit = (principal: Principal, rateClass: RateClass) =>
  Effect.gen(function* () {
    const policy = yield* TenantPolicy;
    const limits = yield* TenantLimits;
    const decision = yield* limits
      .rate(principal.tenantId, rateClass, policy.rate(rateClass))
      // One repeat of a call the platform says is safe to repeat (a spent token twice costs one request of budget).
      .pipe(Effect.retry({ times: 1, while: isRepeatable }), Effect.catchAll(dependencyDown("limits.rate")));
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
        const parsed = parseVmId(raw.value);
        if (Option.isNone(parsed)) {
          yield* rateLimit(principal, rateClass);
          return yield* Effect.fail(vmNotFound());
        }
        return yield* name(parsed.value, (vm) =>
          Effect.gen(function* () {
            // The rate spend (a TenantLimits object call) and the ownership read (Postgres) are independent reads of
            // the caller's own tenant, so they run together; one VM call used to wait for both in turn. They are
            // still judged in the order above: a 429 wins over a 404, and nothing acts before ownership is proven.
            // Named on the answer as `own` (server-timing), so a caller's trace splits this gate from the provider's time.
            const [rated, found] = yield* timedStep("own", Effect.all(
              [
                Effect.either(rateLimit(principal, rateClass)),
                Effect.either(tenantOwnsVm(caller, vm).pipe(Effect.catchAll(dependencyDown("ownership.find")))),
              ],
              { concurrency: 2 },
            ));
            if (Either.isLeft(rated)) return yield* Effect.fail(rated.left);
            if (Either.isLeft(found)) return yield* Effect.fail(found.left);
            const owns = found.right;
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
        // The row is written after the answer (on the Worker), not before it:
        // the caller never waited on it, and the INSERT was a serial database
        // round trip on every mutation's response path (a VM resume included).
        yield* afterResponse(
          store.append(entry).pipe(
            Effect.catchAll(() =>
              Effect.sync(() => console.error(JSON.stringify({ event: "cmux_vm_audit_fallback", ...entry, at: at.toISOString() }))),
            ),
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
