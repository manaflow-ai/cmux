import { hiveStoreForTeam } from "../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive",
    { "cmux.hive.operation": "list" },
    "/api/hive GET failed",
    async ({ hiveTeamID }) => {
      const snapshot = await hiveStoreForTeam(hiveTeamID).list();
      return jsonResponse(snapshot);
    },
  );
}
