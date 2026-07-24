import { handleIrohRoute } from "../../../../services/iroh/routeHandler";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return handleIrohRoute(request, "discover");
}

export async function DELETE(request: Request): Promise<Response> {
  return handleIrohRoute(request, "revoke");
}
