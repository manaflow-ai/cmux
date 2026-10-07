// RFC 9728 §3.1: metadata for the `/api/mcp` resource, at the path-suffixed URL.
import { corsPreflight, protectedResourceMetadataResponse } from "../../../../../services/mcp/oauthRoutes";

export function GET(request: Request): Response {
  return protectedResourceMetadataResponse(request);
}

export function OPTIONS(): Response {
  return corsPreflight();
}
