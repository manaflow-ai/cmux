import { call, ORPCError, type AnyProcedure } from "@orpc/server";

/**
 * Call a dashboard procedure the way the page's server prefetch does and
 * answer with the JSON the REST read used to return: the output with 200, or
 * `{ error: { code: reason } }` with the refusal's status.
 */
export async function procedureResponse(procedure: AnyProcedure, input: unknown, request: Request): Promise<Response> {
  try {
    const output = await call(procedure, input, { context: { request, serverPrefetch: true } });
    return Response.json(output);
  } catch (error) {
    if (!(error instanceof ORPCError)) throw error;
    if (process.env.DEBUG_PROCEDURE) console.error(JSON.stringify((error.cause as { issues?: unknown })?.issues ?? error.message));
    const reason = (error.data as { reason?: string } | undefined)?.reason ?? error.code;
    return Response.json({ error: { code: reason } }, { status: error.status });
  }
}
