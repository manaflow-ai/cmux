import { z } from "zod";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import {
  importOauthCredential,
  publicCredential,
  runCoderouterWorkflow,
} from "../../../../../services/coderouter/workflows";
import {
  authenticateCoderouter,
  coderouterErrorResponse,
  familySchema,
  parseJsonBody,
} from "../../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const importSchema = z.object({
  provider: familySchema,
  accessToken: z.string().min(1),
  refreshToken: z.string().min(1),
  idToken: z.string().min(1).optional(),
  accountId: z.string().min(1).optional(),
  email: z.string().email().optional(),
  expiresAt: z.number().int().positive().optional(),
  label: z.string().trim().min(1).max(160).optional(),
}).strict();

export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const body = await parseJsonBody(request, importSchema);
  if (!body.ok) return body.response;

  try {
    const row = await runCoderouterWorkflow(importOauthCredential({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      label: body.value.label,
      chain: {
        provider: body.value.provider,
        accessToken: body.value.accessToken,
        refreshToken: body.value.refreshToken,
        idToken: body.value.idToken,
        accountId: body.value.accountId,
        email: body.value.email,
        expiresAt: body.value.expiresAt,
      },
    }));
    return jsonResponse(publicCredential(row));
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
