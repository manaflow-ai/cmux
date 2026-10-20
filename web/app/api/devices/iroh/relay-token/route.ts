import { handleTaggedIrohRoute } from "../../../../../services/iroh/routeHandler";


export async function POST(request: Request): Promise<Response> {
  return handleTaggedIrohRoute(request, "relay_token");
}
