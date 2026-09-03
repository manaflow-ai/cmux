import { verifyDomainOrPublication } from "../../../../../../services/vm-publications/workflows";
import { jsonResponse } from "../../../../../../services/vms/routeHelpers";
import {
  publicationForwardAuthConfig,
  publicationGeneratedDomain,
  publicationReference,
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../../../publications/routeShared";

export const maxDuration = 120;

type RouteContext = { readonly params: Promise<{ name: string }> };

/**
 * Verify by domain, not by database id: start or complete a zone's
 * verification, or refresh the publication that serves the named hostname.
 */
export async function POST(request: Request, route: RouteContext): Promise<Response> {
  return withAuthedPublicationApiRoute(request, async (context) => {
    const { name } = await route.params;
    return handleDomainVerify(name, context);
  });
}

export async function handleDomainVerify(
  name: string,
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<Response> {
  const result = await context.run(verifyDomainOrPublication({
    principal: context.principal,
    reference: publicationReference(name, environment),
    generatedDomain: publicationGeneratedDomain(environment),
    forwardAuth: publicationForwardAuthConfig(environment),
  }));
  return jsonResponse(
    result.kind === "publication"
      ? { publication: result.publication }
      : { domain: result.domain },
  );
}
