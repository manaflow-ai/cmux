import { z } from "zod";
import { jsonResponse } from "../../../../../services/vms/routeHelpers";
import { verifyInternalBearer } from "../../../../../services/coderouter/keys";
import {
  ingestUsage,
  runCoderouterWorkflow,
} from "../../../../../services/coderouter/workflows";
import {
  coderouterErrorResponse,
  credentialClassSchema,
  parseJsonBody,
  USAGE_INGEST_JSON_LIMIT_BYTES,
} from "../../_shared";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const eventSchema = z.object({
  eventId: z.string().min(1),
  keyId: z.uuid().optional(),
  credentialId: z.uuid().optional(),
  family: z.string().min(1),
  endpointClass: z.enum(["anthropic", "openai_api", "codex"]),
  model: z.string().min(1).optional(),
  credentialClass: credentialClassSchema,
  status: z.number().int().min(100).max(599),
  inputTokens: z.number().int().nonnegative(),
  outputTokens: z.number().int().nonnegative(),
  cacheReadTokens: z.number().int().nonnegative(),
  cacheWriteTokens: z.number().int().nonnegative(),
  estimated: z.boolean(),
  costMicros: z.number().int().nonnegative().nullable().optional(),
  latencyMs: z.number().int().nonnegative().optional(),
  ts: z.number().int().positive(),
}).strict();

const usageIngestSchema = z.object({
  poolId: z.string().min(1),
  events: z.array(eventSchema).max(500),
  statusUpdates: z.array(z.object({
    credentialId: z.uuid(),
    status: z.enum(["active", "needs_reauth"]),
  }).strict()).optional(),
}).strict();

export async function POST(request: Request): Promise<Response> {
  if (!verifyInternalBearer(request, process.env.CODEROUTER_INTERNAL_TOKEN)) {
    return jsonResponse({ error: "unauthorized", message: "Unauthorized." }, 401);
  }
  const body = await parseJsonBody(request, usageIngestSchema, USAGE_INGEST_JSON_LIMIT_BYTES);
  if (!body.ok) return body.response;
  try {
    const result = await runCoderouterWorkflow(ingestUsage({ usage: body.value }));
    return jsonResponse({ balanceMicros: result.balanceMicros });
  } catch (err) {
    return coderouterErrorResponse(err);
  }
}
