import { RPCHandler } from "@orpc/server/fetch";

import { createORPCContext } from "@/orpc/server/base";
import { router } from "@/orpc/server/router";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const handler = new RPCHandler(router);

async function handleRequest(request: Request): Promise<Response> {
  const { response } = await handler.handle(request, {
    prefix: "/api/rpc",
    context: await createORPCContext(request),
  });

  return response ?? new Response("Not found", { status: 404 });
}

export const HEAD = handleRequest;
export const GET = handleRequest;
export const POST = handleRequest;
export const PUT = handleRequest;
export const PATCH = handleRequest;
export const DELETE = handleRequest;
