import { verifyPublication } from "../../../../../../services/vm-publications/workflows";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../../routeShared";

export const maxDuration = 120;

type RouteContext = { readonly params: Promise<{ id: string }> };

export async function POST(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { id } = await route.params;
    return handlePublicationVerify(request, id, context);
  });
}

export async function handlePublicationVerify(
  request: Request,
  publicationId: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const publication = await context.run(verifyPublication({
    principal: context.principal,
    publicationId,
    forwardAuth: publicationForwardAuthConfig(request, environment),
  }));
  return jsonResponse({ publication });
}
