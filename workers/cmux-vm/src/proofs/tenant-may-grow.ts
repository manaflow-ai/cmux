/** Trusted: growth consumes the tenant's VM plan, without reserving another VM. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import { missingScope, PaymentRequired } from "../errors.ts";
import { keyHasScope } from "./key-has-scope.ts";
import { Entitlements } from "./tenant-may-create.ts";

export interface TenantMayGrow<C> extends Proof<"TenantMayGrow", [C]> {}
const MayGrow = defineProof("TenantMayGrow");
export const tenantMayGrow = <C>(caller: Named<C, Principal>) => Effect.gen(function* () {
  if (keyHasScope(caller, "vm:write") === null) return yield* Effect.fail(missingScope("vm:write"));
  if (!(yield* (yield* Entitlements).mayCreate(caller.value.tenantId, "vm"))) {
    return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include VMs" }));
  }
  const proof: TenantMayGrow<C> = Object.freeze({ ...MayGrow.prove(caller) });
  return proof;
});
