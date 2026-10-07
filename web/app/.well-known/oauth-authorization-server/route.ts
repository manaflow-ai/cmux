import { authorizationServerMetadataResponse, corsPreflight } from "../../../services/mcp/oauthRoutes";

export function GET(request: Request): Response {
  return authorizationServerMetadataResponse(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
