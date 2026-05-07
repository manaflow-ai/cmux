import { hiveNodeInputSchema } from "../../../../services/hive/types";
import { hiveStoreForTeam } from "../../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive/nodes",
    { "cmux.hive.operation": "upsert_node" },
    "/api/hive/nodes POST failed",
    async ({ hiveTeamID }) => {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const parsed = hiveNodeInputSchema.safeParse(body);
      if (!parsed.success) {
        return jsonResponse({ error: "invalid hive node", issues: parsed.error.issues }, 400);
      }
      const node = await hiveStoreForTeam(hiveTeamID).upsertNode(parsed.data);
      return jsonResponse({ node });
    },
  );
}
