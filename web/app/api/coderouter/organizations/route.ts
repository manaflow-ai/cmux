import { organizationsGet } from "../../subrouter/teams/route";

export async function GET(request: Request): Promise<Response> {
  // The catalog exposes membership capabilities, not API-key administration.
  // Keep the per-team API-key permission lookups on the dashboard that uses
  // them; doing them here delays both CLI listing and organization switching.
  return organizationsGet(request);
}
