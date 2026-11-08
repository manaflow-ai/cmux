import { handleTaggedIrohRoute } from "../../../../services/iroh/routeHandler";


export async function GET(request: Request): Promise<Response> {
  return handleTaggedIrohRoute(request, "discover");
}

export async function DELETE(request: Request): Promise<Response> {
  return handleTaggedIrohRoute(request, "revoke");
}
