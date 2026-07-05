import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { verifyInternalBearer } from "../../../../../services/coderouter/keys";
import {
  poolConfigForName,
  runCoderouterWorkflow,
} from "../../../../../services/coderouter/workflows";
import { coderouterErrorResponse } from "../../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  if (!verifyInternalBearer(request, process.env.CODEROUTER_INTERNAL_TOKEN)) {
    return jsonResponse({ error: "unauthorized", message: "Unauthorized." }, 401);
  }
  const poolId = new URL(request.url).searchParams.get("poolId")?.trim();
  if (!poolId) return jsonResponse({ error: "invalid_request", message: "Missing poolId." }, 400);
  try {
    return jsonResponse(await runCoderouterWorkflow(poolConfigForName(poolId)));
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
