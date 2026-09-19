// Resolves the deepest cached env layer for a chain of layer hashes, and reports
// the base image the deployed backend would boot so the CLI hashes against the
// same image id the server will use for layer-0 creates.

import { isProviderId, type ProviderId } from "../../../../../../services/vms/drivers";
import { defaultMemoryMbForPlan } from "../../../../../../services/vms/entitlements";
import { resolveVmImage } from "../../../../../../services/vms/images/resolver";
import {
  jsonResponse,
  resolveVmRouteAccountScope,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { resolveEnvLayers, runVmWorkflow } from "../../../../../../services/vms/workflows";

export const dynamic = "force-dynamic";

const MAX_CHAIN_HASHES = 256;

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/env/layers/resolve",
    { "cmux.vm.operation": "env_resolve_layers" },
    "/api/vm/env/layers/resolve POST failed",
    async ({ user, span }) => {
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return envBadRequest("Cloud VM env layer resolve expected valid JSON.");
      }
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        return envBadRequest("Cloud VM env layer resolve expected a JSON object body.");
      }
      const { provider: rawProvider, chainHashes: rawChainHashes } = body as {
        provider?: unknown;
        chainHashes?: unknown;
      };
      if (rawProvider !== undefined && !isProviderId(rawProvider)) {
        return envBadRequest("`provider` must be freestyle.");
      }
      // Match the only supported Cloud VM provider for provider-less probes.
      const provider: ProviderId = isProviderId(rawProvider) ? rawProvider : "freestyle";
      if (!Array.isArray(rawChainHashes) || rawChainHashes.some((hash) => typeof hash !== "string" || !hash.trim())) {
        return envBadRequest("`chainHashes` must be an array of non-empty strings.");
      }
      if (rawChainHashes.length > MAX_CHAIN_HASHES) {
        return envBadRequest(`\`chainHashes\` supports at most ${MAX_CHAIN_HASHES} entries.`);
      }
      const chainHashes = rawChainHashes as string[];

      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      const billingTeamId = account.entitlements.billingTeamId;
      setSpanAttributes(span, {
        "cmux.vm.provider": provider,
        "cmux.env.chain_count": chainHashes.length,
      });

      const image = resolveVmImage(provider, undefined, process.env, {
        memoryMb: defaultMemoryMbForPlan(account.entitlements.planId, process.env),
      });
      const layer = await runVmWorkflow(resolveEnvLayers({
        billingTeamId,
        provider,
        chainHashes,
      }));

      return jsonResponse({
        provider,
        baseImageId: image.image,
        baseImageVersion: image.imageVersion,
        layer: layer
          ? {
            provider: layer.provider,
            chainHash: layer.chainHash,
            stepIndex: layer.stepIndex,
            stepName: layer.stepName,
            snapshotId: layer.snapshotId,
            specDigest: layer.specDigest,
            baseImageId: layer.baseImageId,
            createdAt: layer.createdAt,
          }
          : null,
      });
    },
  );
}

function envBadRequest(message: string): Response {
  return vmErrorResponse({
    error: "env_invalid_request",
    status: 400,
    message,
    action: "Send `{ \"provider\": \"freestyle\", \"chainHashes\": [\"...\"] }`.",
  });
}
