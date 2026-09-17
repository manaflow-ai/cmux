import { coderouterControlRoute } from "@/services/coderouter/requestTelemetry";
// cmux Reflection: the guest-facing read surface a machine reaches through its
// alias origin (`https://coderouter.cmux.internal/api/vm/reflection[/<path>]`, or
// `https://reflection.cmux.internal/<path>` via the proxy rewrite). The platform
// edge injects the machine's VM-bound route token and `x-cmux-vm-id`; the guest
// itself only sends the public placeholder bearer. Identity comes from that
// injection (services/vms/vmPrincipal.ts) and nothing else: no Stack session is
// accepted here, and no other `/api/vm/*` route accepts a machine.
import { captureCoderouterEvent } from "../../../../../services/coderouter/analytics";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "../../../../../services/coderouter/observability";
import { vmEdgeAliasDomain, vmReflectionAliasDomain } from "../../../../../services/coderouter/vmGuestEnv";
import { reflectionHasDesktop, reflectionPayload, type ReflectionContext } from "../../../../../services/vms/reflection";
import { listOwnerLiveVms, loadReflectionOwner } from "../../../../../services/vms/reflectionStore";
import {
  requireVmPrincipal,
  vmPrincipalFailureResponse,
  type VmPrincipalFailure,
} from "../../../../../services/vms/vmPrincipal";

const JSON_HEADERS = {
  "cache-control": "no-store",
  "content-type": "application/json",
} as const;

/** Failures the coderouter auth analytics already know how to bucket. */
const ROUTE_TOKEN_FAILURES: ReadonlySet<VmPrincipalFailure> = new Set([
  "missing_route_token",
  "invalid_route_token",
  "vm_mismatch",
]);

type RouteContext = { params: Promise<{ path?: string[] }> };

export const GET = coderouterControlRoute<RouteContext>("vm_reflection", "/api/vm/reflection", handleGet);

async function handleGet(request: Request, context?: RouteContext): Promise<Response> {
  const auth = await requireVmPrincipal(request);
  if (!auth.ok) {
    addCoderouterBreadcrumb("auth", "Reflection principal rejected", { path: "vm_reflection", reason: auth.reason }, "warning");
    if (ROUTE_TOKEN_FAILURES.has(auth.reason)) {
      captureCoderouterEvent({
        event: "coderouter_auth_rejected",
        properties: { surface: "vm_reflection", reason: auth.reason },
      });
    }
    return vmPrincipalFailureResponse(auth.reason);
  }
  const { principal } = auth;
  const segments = (await context?.params)?.path ?? [];
  const path = `/${segments.join("/")}`;

  let siblings;
  let owner;
  try {
    [siblings, owner] = await Promise.all([listOwnerLiveVms(principal.vm), loadReflectionOwner(principal)]);
  } catch (error) {
    reportCoderouterFailure("rds", error, { operation: "reflection_load" });
    return new Response(
      JSON.stringify({ error: "reflection_unavailable", retryable: true }),
      { status: 503, headers: { ...JSON_HEADERS, "retry-after": "5" } },
    );
  }

  const reflection: ReflectionContext = {
    self: principal.vm,
    owner,
    siblings,
    aliasOrigin: `https://${vmEdgeAliasDomain()}`,
    reflectionOrigin: `https://${vmReflectionAliasDomain()}`,
    hasDesktop: reflectionHasDesktop(principal.vm),
  };
  const answer = reflectionPayload(path, reflection);
  return new Response(JSON.stringify(answer.body), { status: answer.status, headers: JSON_HEADERS });
}
