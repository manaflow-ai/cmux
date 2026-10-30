import { preconnectCloudDb } from "../../../../../../../db/client";
import { preconnectFreestyle } from "../../../../../../../services/vms/drivers/freestyle";
import { runError, runJson, jsonBodyObject, RunRequestError } from "../../../../../../../services/runs/http";
import {
  consumeRunAttachTicket,
  mintRunAttachTicket,
} from "../../../../../../../services/runs/repository";
import { capabilityList, optionalClientIdentifier } from "../../../../../../../services/vms/routeInput";
import {
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../../../services/vms/routeWorkflow";
import { openVmCmuxRemote } from "../../../../../../../services/vms/workflows";
import { vmModelPlaneRevoker } from "../../../../../../../services/vms/modelPlaneGateway";

/**
 * Mint or redeem the short-lived Run terminal attach ticket.
 *
 * POST without `ticket` returns only opaque ticket material and target ids.
 * POST with `ticket` atomically consumes it, then mints the ordinary
 * cmux-remote endpoint through the existing VM attach authority. Provider
 * credentials never enter the persisted ticket row or the mint response.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string; attemptId: string }> },
): Promise<Response> {
  preconnectCloudDb();
  preconnectFreestyle();
  return withAuthedVmApiRoute(
    request,
    "/api/runs/[id]/attempts/[attemptId]/attach-ticket",
    { "cmux.vm.operation": "run_attach_ticket" },
    "/api/runs attach-ticket POST failed",
    async ({ user }) => {
      const { id, attemptId } = await params;
      const body = jsonBodyObject(await request.json().catch(() => null)) ?? {};
      const suppliedTicket = typeof body.ticket === "string"
        ? body.ticket
        : typeof body.attachTicket === "string"
          ? body.attachTicket
          : undefined;
      try {
        if (!suppliedTicket) {
          const ttlMs = typeof body.ttlMs === "number" ? body.ttlMs : undefined;
          const ticket = await mintRunAttachTicket({ runId: id, attemptId, userId: user.id, ttlMs });
          // Keep this response deliberately free of endpoint credentials. A
          // caller must redeem the one-use ticket to mint a provider endpoint.
          return noStore(runJson({
            ticket: ticket.ticket,
            runId: ticket.runId,
            attemptId: ticket.attemptId,
            provider: ticket.provider,
            providerVmId: ticket.providerVmId,
            providerWorkspaceId: ticket.providerWorkspaceId,
            providerTerminalId: ticket.providerTerminalId,
            expiresAt: ticket.expiresAt,
          }, 201));
        }

        const account = resolveVmRouteAccountScope(user, request);
        if (!account.ok) return account.response;
        const target = await consumeRunAttachTicket({
          runId: id,
          attemptId,
          userId: user.id,
          ticket: suppliedTicket,
        });
        if (target.provider !== "cloud-vm") {
          return noStore(runError(new RunRequestError("run_attach_provider_unsupported", "This run provider does not support terminal attach.", "Choose an attempt from a provider that supports terminal attach and retry.", 409)));
        }
        let deviceFingerprint: string | undefined;
        try {
          deviceFingerprint = optionalClientIdentifier(body.deviceFingerprint ?? body.device_fingerprint, "deviceFingerprint");
        } catch (error) {
          return noStore(runError(new RunRequestError("invalid_request", error instanceof Error ? error.message : "Invalid attach request.", "Provide a valid device fingerprint and retry.")));
        }
        const run = await runVmRoute(openVmCmuxRemote({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          maxActiveVms: account.entitlements.maxActiveVms,
          teamIds: user.teamIds,
          providerVmId: target.providerVmId,
          deviceFingerprint,
          clientCapabilities: capabilityList(body.clientCapabilities ?? body.client_capabilities),
          callerPlanId: account.entitlements.planId,
          modelPlane: vmModelPlaneRevoker(),
        }), { request });
        if (!run.ok) return run.response;
        return noStore(runJson({
          runId: target.runId,
          attemptId: target.attemptId,
          provider: target.provider,
          providerVmId: target.providerVmId,
          providerWorkspaceId: target.providerWorkspaceId,
          providerTerminalId: target.providerTerminalId,
          expiresAt: target.expiresAt,
          endpoint: run.value,
          // Flatten the transport envelope for clients that pass the result
          // straight to the existing cmux remote attach bridge.
          transport: run.value.transport,
          route: run.value.route,
          token: run.value.token,
          session: run.value.session,
          expiresAtUnix: run.value.expiresAtUnix,
        }));
      } catch (error) {
        return noStore(runError(error));
      }
    },
  );
}

function noStore(response: Response): Response {
  response.headers.set("cache-control", "no-store");
  return response;
}
