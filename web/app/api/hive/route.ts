import { hiveStoreForUser } from "../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../services/hive/routeHelpers";
import { jsonResponse } from "../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive",
    { "cmux.hive.operation": "list" },
    "/api/hive GET failed",
    async ({ user }) => {
      const snapshot = await hiveStoreForUser(user.id).list();
      return jsonResponse(snapshot);
    },
  );
}

