import { corsPreflight, revokeRoute } from "../../../../services/mcp/oauthRoutes";

export function POST(request: Request): Promise<Response> {
  return revokeRoute(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
