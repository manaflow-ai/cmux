import {
  jsonResponse,
  resolveVmProvisioningAccountScope,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import {
  PersistentWorkspaceError,
} from "../../../services/vms/persistentWorkspace";
import { persistentWorkspaceServiceForRequest } from "../../../services/vms/freestyleWorkspaceComposition";
import type { PersistentWorkspaceProviderInput } from "../../../services/vms/persistentWorkspace";
import { enforceVmAllocationRateLimit } from "../../../services/vms/allocationRateLimit";

function errorResponse(error: unknown): Response {
  if (error instanceof PersistentWorkspaceError) {
    const status = error.code === "workspace_not_found" ? 404
      : error.code === "workspace_forbidden" ? 403
        : error.code === "workspace_idempotency_conflict" || error.code === "workspace_invalid_state" ? 409
          : error.code === "workspace_input_invalid" ? 400 : 502;
    return jsonResponse({ error: error.code, message: error.message }, status);
  }
  console.error("[workspaces] create failed", error);
  return jsonResponse({ error: "workspace_unavailable", message: "Persistent workspace provisioning is unavailable." }, 503);
}

function objectBody(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function providerInputFrom(value: unknown): PersistentWorkspaceProviderInput | undefined {
  const body = objectBody(value);
  if (!body) return undefined;
  const terminal = objectBody(body.terminal);
  return {
    ...(typeof body.image === "string" ? { image: body.image } : {}),
    ...(typeof body.imageVersion === "string" ? { imageVersion: body.imageVersion } : {}),
    ...(typeof body.memoryMb === "number" && Number.isSafeInteger(body.memoryMb) ? { memoryMb: body.memoryMb } : {}),
    ...(objectBody(body.providerMetadata) ? { providerMetadata: body.providerMetadata as Record<string, unknown> } : {}),
    ...(typeof body.networkId === "string" ? { networkId: body.networkId } : {}),
    ...(terminal ? {
      terminal: {
        ...(terminal.agent === "claude" || terminal.agent === "codex" || terminal.agent === "opencode" || terminal.agent === "pi" ? { agent: terminal.agent } : {}),
        ...(typeof terminal.prompt === "string" ? { prompt: terminal.prompt } : {}),
        ...(typeof terminal.cwd === "string" ? { cwd: terminal.cwd } : {}),
      },
    } : {}),
  };
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/workspaces",
    { "cmux.vm.operation": "workspace_create" },
    "/api/workspaces POST failed",
    async ({ user }) => {
      const idempotencyKey = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim() || "";
      if (!idempotencyKey) return jsonResponse({ error: "workspace_idempotency_required", message: "Idempotency-Key is required." }, 400);
      let body: Record<string, unknown> | null = null;
      try { body = objectBody(await request.json()); } catch { /* malformed input handled below */ }
      if (!body) return jsonResponse({ error: "workspace_invalid_request", message: "Workspace body must be a JSON object." }, 400);
      const scope = await resolveVmProvisioningAccountScope(user, request);
      if (!scope.ok) return scope.response;
      const limited = await enforceVmAllocationRateLimit({
        request,
        route: "workspace.create",
        billingTeamId: scope.entitlements.billingTeamId,
      });
      if (limited) return limited;
      const service = await persistentWorkspaceServiceForRequest({ user, entitlements: scope.entitlements });
      try {
        const workspace = await service.create({
          tenantId: scope.entitlements.billingTeamId ?? user.billingTeamId,
          ownerId: user.id,
          idempotencyKey,
          ...(typeof body.name === "string" ? { workspaceName: body.name } : {}),
          providerInput: providerInputFrom(body.providerInput ?? body),
        });
        return jsonResponse(workspace, 201);
      } catch (error) {
        return errorResponse(error);
      }
    },
  );
}

