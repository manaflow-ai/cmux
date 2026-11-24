import { RPCHandler } from "@orpc/server/fetch";
import { dashboardRouter } from "@/orpc/server/dashboard/router";

const handler = new RPCHandler(dashboardRouter);

// `cloud.resumeMachine` waits for the provider to report the machine running,
// the same budget as `POST /api/vm/{id}/resume`.
export const maxDuration = 960;

async function handleRequest(request: Request): Promise<Response> {
  const { response } = await handler.handle(request, {
    prefix: "/api/dashboard/rpc",
    context: { request },
  });
  if (!response) return new Response("Not found", { status: 404 });
  // Every dashboard procedure answers with the viewer's private data.
  response.headers.set("cache-control", "private, no-store");
  return response;
}

export const GET = handleRequest;
export const POST = handleRequest;
