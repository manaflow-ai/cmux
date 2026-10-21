import { name, type Named } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import type { Principal } from "../domain/principal.ts";
import { unavailable, vmNotFound } from "../errors.ts";
import { parseVmId } from "../lib/ids.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantOwnsVm } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { toVm } from "./vm-view.ts";

/** Answers a replayed create or fork with the VM the first request made. */
export const replayVm = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, rawVmId: string) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const parsed = parseVmId(rawVmId);
    if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
    return yield* name(parsed.value, (vm) =>
      Effect.gen(function* () {
        const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
        if (owns === null) return yield* Effect.fail(vmNotFound());
        const current = yield* upstream.getVmForWrite(vm, { owns, scope }).pipe(Effect.mapError((error) => error.status === 404 ? vmNotFound() : unavailable()));
        return toVm(vm.value, owns, current);
      }),
    );
  });

