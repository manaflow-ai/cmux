import { hiveStoreForUser } from "../../../../services/hive/rivetClient";
import { withAuthedHiveApiRoute } from "../../../../services/hive/routeHelpers";
import { hivePairingInputSchema } from "../../../../services/hive/types";
import { jsonResponse } from "../../../../services/vms/routeHelpers";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedHiveApiRoute(
    request,
    "/api/hive/pairings",
    { "cmux.hive.operation": "upsert_pairing" },
    "/api/hive/pairings POST failed",
    async ({ user }) => {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const parsed = hivePairingInputSchema.safeParse(body);
      if (!parsed.success) {
        return jsonResponse({ error: "invalid hive pairing", issues: parsed.error.issues }, 400);
      }
      const pairing = await hiveStoreForUser(user.id).upsertPairing(parsed.data);
      return jsonResponse({ pairing });
    },
  );
}

