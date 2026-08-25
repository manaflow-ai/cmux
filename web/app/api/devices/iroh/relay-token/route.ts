import { handleIrohRoute } from "../../../../../services/iroh/routeHandler";


export async function POST(request: Request): Promise<Response> {
  return handleIrohRoute(request, "relay_token");
}
