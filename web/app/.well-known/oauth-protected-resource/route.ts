import { corsPreflight, protectedResourceMetadataResponse } from "../../../services/mcp/oauthRoutes";

export function GET(request: Request): Response {
  return protectedResourceMetadataResponse(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
