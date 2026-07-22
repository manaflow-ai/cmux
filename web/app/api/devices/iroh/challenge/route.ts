import { handleIrohRoute } from "../../../../../services/iroh/routeHandler";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return handleIrohRoute(request, "challenge");
}
