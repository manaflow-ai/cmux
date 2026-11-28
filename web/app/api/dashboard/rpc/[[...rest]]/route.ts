import { RPCHandler } from "@orpc/server/fetch";
import { dashboardRouter } from "@/orpc/server/dashboard/router";

const handler = new RPCHandler(dashboardRouter);

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
