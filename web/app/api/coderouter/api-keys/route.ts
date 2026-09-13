import { z } from "zod";

import { coderouterControlRoute } from "../../../../services/coderouter/requestTelemetry";
import {
  createApiKey,
  listApiKeys,
} from "../../../../services/coderouter/repository";
import { resolveCodeRouterRequestContext } from "../../../../services/coderouter/requestContext";
import { captureCoderouterEvent } from "../../../../services/coderouter/analytics";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";
import { readBoundedJsonRecord } from "../../../../services/subrouter/boundedJson";

const MAX_BODY_BYTES = 8 * 1024;
const labelSchema = z.object({ label: z.string().trim().min(1).max(80) }).strict();

export type ApiKeyRouteDependencies = {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly list: typeof listApiKeys;
  readonly create: typeof createApiKey;
};

const defaultDependencies: ApiKeyRouteDependencies = {
  resolve: resolveCodeRouterRequestContext,
  list: listApiKeys,
  create: createApiKey,
};

export function makeApiKeyHandlers(dependencies: ApiKeyRouteDependencies = defaultDependencies) {
  return {
    GET: handleGet.bind(null, dependencies),
    POST: handlePost.bind(null, dependencies),
  };
}

export const GET = coderouterControlRoute("session", "/api/coderouter/api-keys", makeApiKeyHandlers().GET);
export const POST = coderouterControlRoute("session", "/api/coderouter/api-keys", makeApiKeyHandlers().POST);

async function handleGet(dependencies: ApiKeyRouteDependencies, request: Request): Promise<Response> {
  const resolved = await dependencies.resolve(request);
  if (!resolved.ok) return resolved.response;
  try {
    const keys = await dependencies.list(resolved.value.team.teamId);
    captureCoderouterEvent({
      event: "coderouter_api_key_listed",
      userId: resolved.value.user.id,
      teamId: resolved.value.team.teamId,
      properties: { key_count: keys.length },
    });
    return Response.json(
      { teamId: resolved.value.team.teamId, keys },
      { headers: { "cache-control": "no-store" } },
    );
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "list_api_keys" });
    return Response.json(
      { error: "api_key_unavailable", retryable: true },
      { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
    );
  }
}

async function handlePost(dependencies: ApiKeyRouteDependencies, request: Request): Promise<Response> {
  const resolved = await dependencies.resolve(request);
  if (!resolved.ok) return resolved.response;
  if (!resolved.value.team.manageAccounts) {
    return Response.json({ error: "forbidden" }, { status: 403 });
  }
  const body = await readBoundedJsonRecord(request, MAX_BODY_BYTES);
  if (!body.ok) return new Response(null, { status: body.status });
  const parsed = labelSchema.safeParse(body.value);
  if (!parsed.success) return Response.json({ error: "invalid_request" }, { status: 400 });
  try {
    const issued = await dependencies.create(
      resolved.value.team.teamId,
      resolved.value.user.id,
      parsed.data.label,
    );
    captureCoderouterEvent({
      event: "coderouter_api_key_created",
      userId: resolved.value.user.id,
      teamId: resolved.value.team.teamId,
      properties: {},
    });
    return Response.json(
      {
        teamId: resolved.value.team.teamId,
        id: issued.id,
        key: issued.key,
        keyPrefix: issued.keyPrefix,
        label: issued.label,
        createdAt: issued.createdAt.toISOString(),
      },
      { status: 201, headers: { "cache-control": "no-store" } },
    );
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "create_api_key" });
    return Response.json(
      { error: "api_key_unavailable", retryable: true },
      { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
    );
  }
}
