/** Issue a public recovery handle only for requests that omitted their own key. */
import { Clock, Effect, Option } from "effect";
import { CreatedVm, type Vm } from "../api.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import { creationDiscoveryScope, type GeneratedCreation } from "../domain/generated-creation.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { newVmCreationKey, parseVmCreationKey, type VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { requestFingerprint } from "./idempotency.ts";

export const issueCreation = (principal: Principal, operation: "create" | "fork", payload: { readonly displayName?: string; readonly labels?: Readonly<Record<string, string>> }, sourceId?: VmId) => Effect.gen(function* () {
  const key = newVmCreationKey();
  const generated: GeneratedCreation = {
    key, cursor: yield* requestFingerprint(["creation-page:v1", key]), scope: creationDiscoveryScope(principal),
    createdBy: actorRef(principal.actor), createdAt: new Date(yield* Clock.currentTimeMillis).toISOString(),
    operation, displayName: payload.displayName ?? null, labels: payload.labels ?? {},
    ...(sourceId === undefined ? {} : { sourceId }),
  };
  return generated;
});

/** Only server-issued handles are emitted. A supplied key that resembles one is still private. */
export const creationResult = <A extends Vm, E extends object, R>(principal: Principal, key: string, program: Effect.Effect<A, E, R>, issued?: GeneratedCreation) => {
  const retained = Effect.gen(function* () {
    if (Option.isNone(parseVmCreationKey(key))) return undefined;
    const record = yield* (yield* TenantLimits).inspect(principal.tenantId, yield* scopedCreationKey(principal, key));
    return record?.progress.phase === "claimed" ? undefined : record?.generated;
  }).pipe(Effect.catchAll(() => Effect.succeed(undefined)));
  return program.pipe(
    Effect.flatMap((vm) => (issued === undefined ? retained : Effect.succeed(issued)).pipe(Effect.map((generated) =>
      new CreatedVm({ ...vm, ...(generated === undefined ? {} : { creationKey: generated.key }) }),
    ))),
    Effect.catchAll((error) => retained.pipe(Effect.flatMap((generated) =>
      Effect.fail(generated === undefined ? error : Object.assign(error, { creationKey: generated.key })),
    ))),
  );
};
