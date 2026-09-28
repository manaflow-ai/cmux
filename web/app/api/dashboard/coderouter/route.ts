import { isStackConfigured } from "@/app/lib/stack";
import { loadCoderouterDashboard } from "@/services/coderouter/dashboardOverview";
import { jsonResponse } from "@/services/vms/routeHelpers";

const PRIVATE = { "cache-control": "private, no-store" };

/**
 * The coderouter dashboard for one team (`?team=`, else the Stack-selected
 * team). 401 sends the SPA to sign-in, 409 `no_teams` sends it to the
 * dashboard home, and 503 renders recovery in place because a Stack outage is
 * not a signed-out session.
 */
export async function GET(request: Request) {
  if (!isStackConfigured()) {
    return jsonResponse({ error: { code: "not_configured" } }, 404, PRIVATE);
  }
  const team = new URL(request.url).searchParams.get("team") ?? undefined;
  const result = await loadCoderouterDashboard(request, team);
  switch (result.kind) {
    case "ok":
      return jsonResponse(result.body, 200, PRIVATE);
    case "missing":
      return jsonResponse({ error: { code: "unauthorized" } }, 401, PRIVATE);
    case "noTeams":
      return jsonResponse({ error: { code: "no_teams" } }, 409, PRIVATE);
    case "unavailable":
      return jsonResponse({ error: { code: "authorization_unavailable" } }, 503, PRIVATE);
  }
}
