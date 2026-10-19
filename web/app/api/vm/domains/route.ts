import { listCustomDomains } from "../../../../services/vm-publications/workflows";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  withAuthedPublicationApiRoute,
  type AuthedPublicationRouteContext,
} from "../publications/routeShared";

export const maxDuration = 60;

/** The custom zones this account owns, listed apart from the publications routed through them. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedPublicationApiRoute(request, (context) =>
    handleCustomDomainList(context));
}

export async function handleCustomDomainList(
  context: Pick<AuthedPublicationRouteContext, "principal" | "run">,
): Promise<Response> {
  const domains = await context.run(listCustomDomains({
    principal: context.principal,
  }));
  return jsonResponse({ domains });
}
