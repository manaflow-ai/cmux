import * as Effect from "effect/Effect";
import { resolveVmRouteAccountScope, withAuthedVmApiRoute, jsonResponse } from "../vms/routeHelpers";
import type { RunScope } from "./repository";

export class RunHttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
export function runNotFound(): never { throw new RunHttpError(404, "run_not_found", "Run not found"); }
export function validRunId(id: string) { if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) runNotFound(); return id; }

/** Existing Cloud auth and team resolution own every Run entry point. */
export function withRunRoute(request: Request, route: string, work: (scope: RunScope) => Promise<Response>): Promise<Response> {
  return withAuthedVmApiRoute(request, route, { "cmux.vm.operation": "run.api" }, `${route} failed`, async ({ user }) => {
    const account = resolveVmRouteAccountScope(user, request);
    if (!account.ok) return account.response;
    const scope = { userId: user.id, ownerTeamId: account.entitlements.billingTeamId };
    const program = Effect.tryPromise(() => work(scope)).pipe(Effect.catchAll((error) => {
      // Effect.tryPromise preserves a rejected Error directly. Some callers
      // may wrap it in Error.cause, so accept both forms without exposing the
      // underlying provider or database failure.
      const cause = error instanceof RunHttpError
        ? error
        : error instanceof Error && error.cause instanceof RunHttpError
          ? error.cause
          : null;
      if (cause) return Effect.succeed(jsonResponse({ error: cause.code, message: cause.message }, cause.status));
      // Never send provider/SQL errors or bound query parameters to clients.
      return Effect.succeed(jsonResponse({ error: "run_unavailable", message: "Run request failed; use its trace id for support." }, 500));
    }));
    return Effect.runPromise(program);
  });
}
