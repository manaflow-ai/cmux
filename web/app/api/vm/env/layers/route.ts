// Register (POST) and list (GET) env-layer cache entries. A layer maps a chain
// hash to a provider snapshot taken after that step succeeded; ownership of the
// snapshot is re-verified server-side before the layer becomes restorable.

import { defaultProviderId, type ProviderId } from "../../../../../services/vms/drivers";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../services/telemetry";
import { listEnvLayers, recordEnvLayer, runVmWorkflow } from "../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/env/layers",
    { "cmux.vm.operation": "env_record_layer" },
    "/api/vm/env/layers POST failed",
    async ({ user, span }) => {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return envBadRequest("Cloud VM env layer registration expected valid JSON.");
      }
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return envBadRequest("Cloud VM env layer registration expected a JSON object body.");
      }
      const candidate = body as Record<string, unknown>;
      if (candidate.provider !== undefined && !isKnownProvider(candidate.provider)) {
        return envBadRequest("`provider` must be one of e2b, freestyle, daytona.");
      }
      const provider: ProviderId = isKnownProvider(candidate.provider)
        ? candidate.provider
        : defaultProviderId();
      const baseImageId = requiredString(candidate.baseImageId);
      const chainHash = requiredString(candidate.chainHash);
      const specDigest = requiredString(candidate.specDigest);
      const snapshotId = requiredString(candidate.snapshotId);
      const stepIndex = candidate.stepIndex;
      const stepName = typeof candidate.stepName === "string" && candidate.stepName.trim()
        ? candidate.stepName.trim()
        : null;
      if (!baseImageId || !chainHash || !specDigest || !snapshotId) {
        return envBadRequest("`baseImageId`, `chainHash`, `specDigest`, and `snapshotId` are required strings.");
      }
      if (typeof stepIndex !== "number" || !Number.isInteger(stepIndex) || stepIndex < 0) {
        return envBadRequest("`stepIndex` must be a non-negative integer.");
      }

      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, {
        "cmux.vm.provider": provider,
        "cmux.env.step_index": stepIndex,
      });

      const layer = await runVmWorkflow(recordEnvLayer({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        billingPlanId: account.entitlements.planId,
        provider,
        baseImageId,
        chainHash,
        stepIndex,
        stepName,
        specDigest,
        snapshotId,
      }));

      return jsonResponse({
        id: layer.id,
        chainHash: layer.chainHash,
        stepIndex: layer.stepIndex,
        stepName: layer.stepName,
        snapshotId: layer.snapshotId,
        specDigest: layer.specDigest,
        baseImageId: layer.baseImageId,
        createdAt: layer.createdAt,
      });
    },
  );
}

export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/env/layers",
    { "cmux.vm.operation": "env_list_layers" },
    "/api/vm/env/layers GET failed",
    async ({ user, span }) => {
      const url = new URL(request.url);
      const rawProvider = url.searchParams.get("provider") ?? undefined;
      if (rawProvider !== undefined && !isKnownProvider(rawProvider)) {
        return envBadRequest("`provider` must be one of e2b, freestyle, daytona.");
      }
      const specDigest = url.searchParams.get("specDigest") ?? undefined;

      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;

      const layers = await runVmWorkflow(listEnvLayers({
        billingTeamId: account.entitlements.billingTeamId,
        provider: rawProvider as ProviderId | undefined,
        specDigest: specDigest || undefined,
      }));
      setSpanAttributes(span, { "cmux.env.layer_count": layers.length });

      return jsonResponse({
        layers: layers.map((layer) => ({
          id: layer.id,
          provider: layer.provider,
          baseImageId: layer.baseImageId,
          chainHash: layer.chainHash,
          stepIndex: layer.stepIndex,
          stepName: layer.stepName,
          snapshotId: layer.snapshotId,
          specDigest: layer.specDigest,
          createdAt: layer.createdAt,
          lastUsedAt: layer.lastUsedAt,
        })),
      });
    },
  );
}

function isKnownProvider(value: unknown): value is ProviderId {
  return value === "e2b" || value === "freestyle" || value === "daytona";
}

function requiredString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function envBadRequest(message: string): Response {
  return vmErrorResponse({
    error: "env_invalid_request",
    status: 400,
    message,
    action: "See `cmux vm env --help` for the layer registration contract.",
  });
}
