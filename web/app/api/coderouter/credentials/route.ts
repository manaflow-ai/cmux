import { z } from "zod";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  addByokCredential,
  disableCredential,
  listCredentials,
  publicCredential,
  runCoderouterWorkflow,
} from "../../../../services/coderouter/workflows";
import {
  authenticateCoderouter,
  coderouterErrorResponse,
  familySchema,
  parseJsonBody,
} from "../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const addByokSchema = z.object({
  family: familySchema,
  label: z.string().trim().min(1).max(160).optional(),
  apiKey: z.string().trim().min(1),
}).strict();

export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  try {
    const rows = await runCoderouterWorkflow(listCredentials(auth.context.teamId));
    return jsonResponse({ credentials: rows.map(publicCredential) });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}

export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const body = await parseJsonBody(request, addByokSchema);
  if (!body.ok) return body.response;

  try {
    const row = await runCoderouterWorkflow(addByokCredential({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      family: body.value.family,
      label: body.value.label,
      apiKey: body.value.apiKey,
    }));
    return jsonResponse(publicCredential(row));
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}

export async function DELETE(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const id = new URL(request.url).searchParams.get("id")?.trim();
  if (!id) return jsonResponse({ error: "invalid_request", message: "Missing credential id." }, 400);
  try {
    const row = await runCoderouterWorkflow(disableCredential({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      credentialId: id,
    }));
    return jsonResponse(publicCredential(row));
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
