import { handleIrohRoute } from "../../../../services/iroh/routeHandler";


export async function GET(request: Request): Promise<Response> {
  return handleIrohRoute(request, "discover");
}

export async function DELETE(request: Request): Promise<Response> {
  return handleIrohRoute(request, "revoke");
}
