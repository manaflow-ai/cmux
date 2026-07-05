import { z } from "zod";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import {
  pollOpenAIConnect,
  publicCredential,
  runCoderouterWorkflow,
  startOpenAIConnect,
} from "../../../../../services/coderouter/workflows";
import {
  authenticateCoderouter,
  coderouterErrorResponse,
  parseJsonBody,
} from "../../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const connectSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("start") }).strict(),
  z.object({ action: z.literal("poll"), deviceCode: z.string().min(1) }).strict(),
]);

export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const body = await parseJsonBody(request, connectSchema);
  if (!body.ok) return body.response;

  try {
    if (body.value.action === "start") {
      return jsonResponse(await runCoderouterWorkflow(startOpenAIConnect()));
    }
    const result = await runCoderouterWorkflow(pollOpenAIConnect({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      deviceCode: body.value.deviceCode,
    }));
    if (result.status === "pending") return jsonResponse({ status: "pending" });
    return jsonResponse({ status: "complete", credential: publicCredential(result.credential) });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
