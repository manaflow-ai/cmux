import { hiveStoreForTeam } from "../../../../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive/pairings/[id]/secret",
    { "cmux.hive.operation": "pairing_secret" },
    "/api/hive/pairings/[id]/secret GET failed",
    async ({ hiveTeamID }) => {
      const { id } = await params;
      const secret = await hiveStoreForTeam(hiveTeamID).getPairingSecret(id);
      if (!secret) {
        return jsonResponse({ error: "pairing not found" }, 404);
      }
      return jsonResponse(secret);
    },
  );
}
