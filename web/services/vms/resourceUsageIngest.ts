import { Effect } from "effect";
import { readBoundedJsonObject } from "../apns/routePolicy";
import { parseVmResourceUsage, VM_RESOURCE_USAGE_KEY, type VmResourceUsage } from "./resourceUsage";
import { vmPrincipalFailureStatus, type VmPrincipalResult, type VmPrincipalRow } from "./vmPrincipalContract";

export type VmResourceUsageIngestDependencies = {
  readonly authenticate: (request: Request) => Promise<VmPrincipalResult>;
  readonly accept: (vm: VmPrincipalRow, usage: VmResourceUsage, receivedAt: number) => Promise<void>;
  readonly now: () => number;
};

/** A machine can update only its own advisory gauges, through its existing edge identity. */
export function makeVmResourceUsageHandler(deps: VmResourceUsageIngestDependencies) {
  return (request: Request): Promise<Response> => Effect.runPromise(
    Effect.gen(function* () {
      const auth = yield* Effect.tryPromise(() => deps.authenticate(request));
      if (!auth.ok) return response(vmPrincipalFailureStatus(auth.reason), auth.reason);
      const body = yield* Effect.tryPromise(() => readBoundedJsonObject(request, 1024));
      if (!body.ok) return response(body.error === "request_too_large" ? 413 : 400, body.error);
      const usage = parseVmResourceUsage(body.value);
      if (!usage) return response(400, "invalid_resource_usage");
      const vm = auth.principal.vm;
      if (!vm.providerVmId) return response(409, "vm_not_ready");
      const now = deps.now();
      const previous = vm.providerMetadata[VM_RESOURCE_USAGE_KEY] as { receivedAt?: unknown } | undefined;
      if (typeof previous?.receivedAt === "number" && now >= previous.receivedAt && now - previous.receivedAt < 15_000) {
        return response(204);
      }
      yield* Effect.tryPromise(() => deps.accept(vm, usage, now));
      return response(204);
    }).pipe(Effect.catchAll(() => Effect.succeed(response(503, "resource_usage_unavailable")))),
  );
}

function response(status: number, error?: string): Response {
  return new Response(error ? JSON.stringify({ error }) : null, {
    status, headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
