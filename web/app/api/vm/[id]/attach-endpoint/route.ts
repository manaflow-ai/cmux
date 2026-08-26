import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { optionalVmClientIdentifier } from "../../../../../services/vms/requestSchemas";
import { openAttachEndpoint, runVmWorkflow } from "../../../../../services/vms/workflows";


export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/attach-endpoint",
    { "cmux.vm.operation": "open_attach" },
    "/api/vm/[id]/attach-endpoint failed",
    async ({ user, span }) => {
      const { id } = await params;
      const body = await parseAttachBody(request);
      const requireDaemon = body.requireDaemon === true || body.require_daemon === true;
      const sessionIdResult = optionalVmClientIdentifier(body.sessionId ?? body.session_id, "sessionId");
      if (!sessionIdResult.ok) {
        return jsonResponse({ error: "invalid_request", message: sessionIdResult.message }, 400);
      }
      const attachmentIdResult = optionalVmClientIdentifier(
        body.attachmentId ?? body.attachment_id,
        "attachmentId",
      );
      if (!attachmentIdResult.ok) {
        return jsonResponse({ error: "invalid_request", message: attachmentIdResult.message }, 400);
      }
      const sessionId = sessionIdResult.value;
      const attachmentId = attachmentIdResult.value;
      const sessionTitle = optionalString(body.title ?? body.sessionTitle ?? body.session_title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      if (sessionId) setSpanAttributes(span, { "cmux.vm.attach.session_id": sessionId });
      try {
        const endpoint = await runVmWorkflow(openAttachEndpoint({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
          sessionTitle,
          options: { requireDaemon, sessionId, attachmentId },
        }));
        setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
        return jsonResponse(endpoint);
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

async function parseAttachBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" && !Array.isArray(body)
      ? body as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}
