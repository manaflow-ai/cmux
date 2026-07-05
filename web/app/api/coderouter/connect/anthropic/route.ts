import { z } from "zod";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import {
  completeAnthropicConnect,
  publicCredential,
  runCoderouterWorkflow,
  startAnthropicConnect,
} from "../../../../../services/coderouter/workflows";
import {
  authenticateCoderouter,
  coderouterErrorResponse,
  cookieValue,
  parseJsonBody,
} from "../../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const STATE_COOKIE = "coderouter_anthropic_state";
const connectSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("start") }).strict(),
  z.object({ action: z.literal("complete"), code: z.string().min(1) }).strict(),
]);

export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const body = await parseJsonBody(request, connectSchema);
  if (!body.ok) return body.response;

  try {
    if (body.value.action === "start") {
      const started = await runCoderouterWorkflow(startAnthropicConnect());
      const response = jsonResponse({ authorizeUrl: started.authorizeUrl, state: started.state });
      response.headers.set(
        "set-cookie",
        `${STATE_COOKIE}=${started.cookie}; HttpOnly; SameSite=Lax; Secure; Path=/api/coderouter/connect/anthropic; Max-Age=600`,
      );
      return response;
    }

    const row = await runCoderouterWorkflow(completeAnthropicConnect({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      pastedCode: body.value.code,
      stateCookie: cookieValue(request, STATE_COOKIE),
    }));
    const response = jsonResponse(publicCredential(row));
    response.headers.set(
      "set-cookie",
      `${STATE_COOKIE}=; HttpOnly; SameSite=Lax; Secure; Path=/api/coderouter/connect/anthropic; Max-Age=0`,
    );
    return response;
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
