import { planeStatus } from "../../../services/coderouter/planeStatus";
import { reportCoderouterFailure } from "../../../services/coderouter/observability";

/** A machine asks which of its agents will work right now (route-token scoped). */
export async function GET(request: Request): Promise<Response> {
  try {
    return await planeStatus(request);
  } catch (error) {
    reportCoderouterFailure("proxy_unhandled", error, { surface: "status" });
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
