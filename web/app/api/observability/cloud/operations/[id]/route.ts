import { Effect } from "effect";
import { verifyRequest } from "../../../../../../services/vms/auth";
import { cloudOperationId, readCloudOperationProgress } from "../../../../../../services/observability/cloudOperationProgress";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }): Promise<Response> {
  return Effect.runPromise(Effect.gen(function* () {
    const params = yield* Effect.tryPromise(() => context.params);
    const id = cloudOperationId(params.id);
    if (!id) return new Response(null, { status: 400 });
    const user = yield* Effect.tryPromise(() => verifyRequest(request, { allowCookie: false }));
    if (!user) return new Response(null, { status: 401 });
    const steps = yield* Effect.tryPromise(() => readCloudOperationProgress(user.id, id));
    return new Response(JSON.stringify({ operationId: id, steps }), {
      headers: { "content-type": "application/json", "cache-control": "no-store" },
    });
  }).pipe(Effect.catchAll(() => Effect.succeed(new Response(null, { status: 503, headers: { "retry-after": "5" } })))));
}
