import { hiveStoreForTeam } from "../../../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive/nodes/[id]",
    { "cmux.hive.operation": "unlink_node" },
    "/api/hive/nodes/[id] DELETE failed",
    async ({ hiveTeamID }) => {
      const { id } = await params;
      const node = await hiveStoreForTeam(hiveTeamID).unlinkNode(id);
      if (!node) {
        return jsonResponse({ error: "node not found" }, 404);
      }
      return jsonResponse({ node });
    },
  );
}
