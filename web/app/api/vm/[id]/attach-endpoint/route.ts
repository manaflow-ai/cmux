import { preconnectCloudDb } from "../../../../../db/client";
import { preconnectFreestyle } from "../../../../../services/vms/drivers/freestyle";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  runAfterResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { VmTimingRecorder } from "../../../../../services/vms/timings";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { openAttachEndpoint, openVmCmuxRemote } from "../../../../../services/vms/workflows";
import {
  capabilityList,
  optionalClientIdentifier,
  optionalString,
  parseLenientObjectBody,
} from "../../../../../services/vms/routeInput";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  // Warm the Freestyle and database connections while the caller is being verified.
  preconnectFreestyle();
  preconnectCloudDb();
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/attach-endpoint",
    { "cmux.vm.operation": "open_attach" },
    "/api/vm/[id]/attach-endpoint failed",
    async ({ user, span, authDurationMs, routeStartedAtMs, setResponseFinalizer }) => {
      const timing = new VmTimingRecorder(span, "open_attach", { startedAt: routeStartedAtMs });
      timing.record("auth", authDurationMs);
      setResponseFinalizer((response) => {
        timing.finish({ status: response.status });
        // Per-stage timings travel with the response, as on create, so a
        // client or a bench run sees where an attach spent its time.
        try {
          response.headers.set("Server-Timing", timing.serverTimingHeader());
        } catch {
          // Immutable headers on a passthrough Response: the span still has them.
        }
      });
      const { id } = await params;
      const body = await parseLenientObjectBody(request);
      const requireDaemon = body.requireDaemon === true || body.require_daemon === true;
      let sessionId: string | undefined;
      let attachmentId: string | undefined;
      try {
        sessionId = optionalClientIdentifier(body.sessionId ?? body.session_id, "sessionId");
        attachmentId = optionalClientIdentifier(body.attachmentId ?? body.attachment_id, "attachmentId");
      } catch (err) {
        return jsonResponse({
          error: "invalid_request",
          message: err instanceof Error ? err.message : "Invalid Cloud VM attach request.",
        }, 400);
      }
      const sessionTitle = optionalString(body.title ?? body.sessionTitle ?? body.session_title);
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      // Transport selection: "cmux-remote" is the cmux-tui remote daemon, the only
      // transport current Cloud machines serve. Clients that do not ask may use a
      // legacy WebSocket PTY/RPC endpoint only if a future provider advertises one;
      // a cmux-tui-only machine answers 409 vm_attach_transport_unsupported.
      const transport = optionalString(body.transport);
      if (transport === "cmux-remote") {
        let deviceFingerprint: string | undefined;
        try {
          deviceFingerprint = optionalClientIdentifier(body.deviceFingerprint ?? body.device_fingerprint, "deviceFingerprint");
        } catch (err) {
          return jsonResponse({
            error: "invalid_request",
            message: err instanceof Error ? err.message : "Invalid Cloud VM attach request.",
          }, 400);
        }
        const clientCapabilities = capabilityList(body.clientCapabilities ?? body.client_capabilities);
        setSpanAttributes(span, { "cmux.vm.attach.transport": "cmux-remote" });
        const run = await runVmRoute(openVmCmuxRemote({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          maxActiveVms: account.entitlements.maxActiveVms,
          teamIds: user.teamIds,
          providerVmId: id,
          deviceFingerprint,
          clientCapabilities,
          callerPlanId: account.entitlements.planId,
          timing,
          // The attach usage event and the address backfill are written
          // after the response has left.
          defer: runAfterResponse,
        }), { request });
        if (!run.ok) return run.response;
        return jsonResponse(run.value);
      }
      if (transport && transport !== "websocket") {
        return jsonResponse({
          error: "invalid_request",
          message: `Unknown attach transport "${transport}". Use "websocket" or "cmux-remote".`,
        }, 400);
      }
      setSpanAttributes(span, { "cmux.vm.attach.require_daemon": requireDaemon });
      if (sessionId) setSpanAttributes(span, { "cmux.vm.attach.session_id": sessionId });
      const run = await runVmRoute(openAttachEndpoint({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        maxActiveVms: account.entitlements.maxActiveVms,
        callerPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        sessionTitle,
        options: { requireDaemon, sessionId, attachmentId },
      }), { request });
      if (!run.ok) return run.response;
      const endpoint = run.value;
      setSpanAttributes(span, { "cmux.vm.attach.transport": endpoint.transport });
      return jsonResponse(endpoint);
    },
  );
}
