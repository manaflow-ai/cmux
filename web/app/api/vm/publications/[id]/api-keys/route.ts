import { createPublicationApiKey, listPublicationApiKeys } from "../../../../../../services/vm-publications/apiKeys";
import { parseRequiredObjectBody } from "../../../../../../services/vms/routeInput";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  publicationReference,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../../routeShared";

export const maxDuration = 120;

type RouteContext = { readonly params: Promise<{ id: string }> };

export async function GET(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id } = await route.params;
    return jsonResponse({
      apiKeys: await context.run(listPublicationApiKeys({ principal: context.principal, publicationId: publicationReference(id) })),
    });
  });
}

export async function POST(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) =>
    handleApiKeyCreate(request, (await route.params).id, context));
}

/** The key is in this response only; CMUX keeps its hash. */
export async function handleApiKeyCreate(
  request: Request,
  publicationId: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const parsed = await parseRequiredObjectBody(request, {
    operation: "API key create",
    action: "Send JSON with an optional name and expiresAt.",
  });
  if (!parsed.ok) return parsed.response;
  const minted = await context.run(createPublicationApiKey({
    principal: context.principal,
    publicationId: publicationReference(publicationId, environment),
    name: parsed.body?.name,
    expiresAt: parsed.body?.expiresAt,
    forwardAuth: publicationForwardAuthConfig(environment),
  }));
  return jsonResponse(minted, 201, { "cache-control": "no-store" });
}
