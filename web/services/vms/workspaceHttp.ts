import { issueHugeBlueAttachToken } from "./hugeBlueAttachTokens";
import {
  PersistentWorkspaceError,
  type PersistentWorkspaceProviderInput,
  type PersistentWorkspaceService,
} from "./persistentWorkspace";
import { DrizzlePersistentWorkspaceStore } from "../runtimeComposition";

export function workspaceJson(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store", "referrer-policy": "no-referrer" } });
}

function errorResponse(error: unknown): Response {
  if (!(error instanceof PersistentWorkspaceError)) return workspaceJson({ error: "workspace_unavailable" }, 503);
  const status = error.code === "workspace_not_found" ? 404
    : error.code === "workspace_forbidden" ? 403
      : error.code === "workspace_idempotency_conflict" || error.code === "workspace_invalid_state" ? 409 : 502;
  return workspaceJson({ error: error.code, message: error.message }, status);
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
    ...(terminal ? { terminal: { agent: "codex", ...(typeof terminal.prompt === "string" ? { prompt: terminal.prompt } : {}), ...(typeof terminal.cwd === "string" ? { cwd: terminal.cwd } : {}) } } : {}),
  };
}

export function workspaceHttp(
  request: Request,
  service: PersistentWorkspaceService,
  scope: { readonly ownerId: string; readonly tenantId: string },
  runtimeId?: string,
): Promise<Response> {
  return (async () => {
    const body = request.method === "POST" ? await request.json().catch(() => null) : null;
    if (!runtimeId) {
      if (request.method !== "POST") return workspaceJson({ error: "method_not_allowed" }, 405);
      const idempotencyKey = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim() || "";
      if (!idempotencyKey) return workspaceJson({ error: "workspace_idempotency_required" }, 400);
      const input = objectBody(body);
      if (!input) return workspaceJson({ error: "workspace_invalid_request" }, 400);
      try {
        return workspaceJson(await service.create({
          tenantId: scope.tenantId,
          ownerId: scope.ownerId,
          idempotencyKey,
          provider: "huge-blue",
          workspaceName: typeof input.name === "string" ? input.name : "Persistent workspace",
          providerInput: providerInputFrom(input.providerInput ?? input),
        }), 201);
      } catch (error) { return errorResponse(error); }
    }
    const action = objectBody(body)?.action;
    if (action === "rotate") {
      const record = await new DrizzlePersistentWorkspaceStore().getRuntime({ runtimeId });
      if (!record || record.ownerId !== scope.ownerId || record.tenantId !== scope.tenantId) return workspaceJson({ error: "workspace_not_found" }, 404);
      if (record.lifecycle !== "running") return workspaceJson({ error: "workspace_invalid_state" }, 409);
      try {
        const target = { ...(await issueHugeBlueAttachToken({ runtimeId, ownerId: scope.ownerId, tenantId: scope.tenantId })), providerWorkspaceId: record.providerWorkspaceId, providerTerminalId: record.providerTerminalId };
        return workspaceJson({ redacted: true, provider: record.provider, runtimeId, workspaceId: record.workspaceId, target });
      } catch (error) { return errorResponse(error); }
    }
    try {
      const lookup = { runtimeId, ownerId: scope.ownerId, tenantId: scope.tenantId };
      if (action === "attach") {
        // The public service view intentionally redacts bearer material. The
        // loopback staging harness is the authenticated client boundary, so
        // mint the short-lived relay capability here and return it only to
        // that caller (the relay rechecks the DB on every upgrade).
        const record = await new DrizzlePersistentWorkspaceStore().getRuntime({ runtimeId });
        if (!record || record.lifecycle !== "running") return workspaceJson({ error: "workspace_invalid_state" }, 409);
        const view = await service.attach(lookup);
        const target = {
          ...(await issueHugeBlueAttachToken({ runtimeId, ownerId: scope.ownerId, tenantId: scope.tenantId })),
          providerWorkspaceId: record.providerWorkspaceId,
          providerTerminalId: record.providerTerminalId,
        };
        return workspaceJson({
          redacted: true,
          provider: view.provider,
          runtimeId: view.runtimeId,
          workspaceId: view.workspaceId,
          target,
        });
      }
      if (action === "resume") return workspaceJson(await service.resume(lookup));
      if (action === "suspend") return workspaceJson(await service.suspend(lookup));
      if (action === "stop") return workspaceJson(await service.stop(lookup));
      return workspaceJson({ error: "workspace_action_invalid" }, 400);
    } catch (error) { return errorResponse(error); }
  })();
}
