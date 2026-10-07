import { corsPreflight, tokenRoute } from "../../../../services/mcp/oauthRoutes";

export function POST(request: Request): Promise<Response> {
  return tokenRoute(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
