import { corsPreflight, registerRoute } from "../../../../services/mcp/oauthRoutes";

export function POST(request: Request): Promise<Response> {
  return registerRoute(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
