import { recordSpanError, withApiRouteSpan, type MaybeAttributes } from "../telemetry";

export async function withApnsApiRoute(
  request: Request,
  route: string,
  operation: string,
  handler: () => Promise<Response>,
): Promise<Response> {
  return withApiRouteSpan(
    request,
    route,
    {
      "cmux.subsystem": "apns",
      "cmux.apns.operation": operation,
    } satisfies MaybeAttributes,
    async (span) => {
      try {
        return await handler();
      } catch (error) {
        recordSpanError(span, error);
        console.error(`${route} ${operation} failed`, error);
        return new Response(JSON.stringify({ error: "push_internal_error" }), {
          status: 500,
          headers: { "content-type": "application/json" },
        });
      }
    },
  );
}
