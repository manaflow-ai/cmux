import { z } from "zod";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  allowedClassesPolicy,
  createKey,
  listKeys,
  publicKey,
  revokeKey,
  runCoderouterWorkflow,
} from "../../../../services/coderouter/workflows";
import {
  authenticateCoderouter,
  coderouterErrorResponse,
  keyPolicySchema,
  parseJsonBody,
} from "../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const createKeySchema = z.object({
  name: z.string().trim().min(1).max(120),
  policy: keyPolicySchema,
}).strict();

export async function GET(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  try {
    const rows = await runCoderouterWorkflow(listKeys(auth.context.teamId));
    return jsonResponse({ keys: rows.map(publicKey) });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}

export async function POST(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const body = await parseJsonBody(request, createKeySchema);
  if (!body.ok) return body.response;

  try {
    const result = await runCoderouterWorkflow(createKey({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      name: body.value.name,
      policy: allowedClassesPolicy(body.value.policy?.allowedClasses),
    }));
    return jsonResponse({ key: result.key, ...publicKey(result.row) });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}

export async function DELETE(request: Request): Promise<Response> {
  const auth = await authenticateCoderouter(request);
  if (!auth.ok) return auth.response;
  const id = new URL(request.url).searchParams.get("id")?.trim();
  if (!id) return jsonResponse({ error: "invalid_request", message: "Missing key id." }, 400);
  try {
    const row = await runCoderouterWorkflow(revokeKey({
      teamId: auth.context.teamId,
      billingCustomer: auth.context.billingCustomer,
      keyId: id,
    }));
    return jsonResponse(publicKey(row));
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
