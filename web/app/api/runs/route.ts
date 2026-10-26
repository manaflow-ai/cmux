import { resolveVmProvisioningAccountScope, runAfterResponse, withAuthedVmApiRoute } from "../../../services/vms/routeHelpers";
import { runError, runJson, jsonBodyObject, RunRequestError } from "../../../services/runs/http";
import { requestDigest } from "../../../services/runs/repository";
import { launchQueuedCloudVmAttempts } from "../../../services/runs/dogfood";
import { ALLOWED_RUN_RECIPES, type RunRoutingRequest } from "../../../services/runs/model";
import { runAdmissionFor, runRoutingFor } from "../../../services/runs/view";
import { createRunWithAllocationAdmission } from "../../../services/runs/allocationAdmission";

export const maxDuration = 960;

type ParsedRunBody = {
  readonly source: { readonly repository?: string; readonly ref?: string; readonly commit: string };
  readonly recipe: string;
  readonly desiredAttempts: number;
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
};

type ParsedProviderRouting = {
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
};

function parseProviderRouting(body: Record<string, unknown>): ParsedProviderRouting | Response {
  if (body.provider !== undefined && body.provider !== "cloud-vm") return runError(new RunRequestError("run_provider_invalid", "The MVP provider is cloud-vm.", "Set provider to cloud-vm and retry."));
  const routingBody = jsonBodyObject(body.routing);
  const requestedProvider = routingBody?.requestedProvider;
  if (requestedProvider !== undefined && requestedProvider !== "freestyle" && requestedProvider !== "huge-blue" && requestedProvider !== "unknown") {
    return runError(new RunRequestError("run_provider_invalid", "routing.requestedProvider must be freestyle, huge-blue, or unknown.", "Set routing.requestedProvider to freestyle, huge-blue, or unknown and retry."));
  }
  return {
    provider: "cloud-vm",
    routing: { ...(requestedProvider !== undefined ? { requestedProvider } : {}) },
  };
}

function parseCreateRunBody(body: Record<string, unknown>): ParsedRunBody | Response {
  const source = jsonBodyObject(body.source);
  const repository = typeof source?.repository === "string" ? source.repository.trim() : "";
  const commit = typeof source?.commit === "string" ? source.commit.trim() : "";
  const recipe = typeof body.recipe === "string" ? body.recipe.trim() : "";
  const desiredAttempts = typeof body.desiredAttempts === "number" && Number.isSafeInteger(body.desiredAttempts)
    ? body.desiredAttempts : 1;
  if (!/^[0-9a-f]{40}$/i.test(commit)) return runError(new RunRequestError("run_source_required", "source.commit must be a 40-character immutable commit SHA.", "Provide a 40-character commit SHA and retry."));
  if (!repository || repository.length > 512) return runError(new RunRequestError("run_source_required", "source.repository is required.", "Provide source.repository and retry."));
  if (!ALLOWED_RUN_RECIPES.includes(recipe as (typeof ALLOWED_RUN_RECIPES)[number])) return runError(new RunRequestError("run_recipe_required", "recipe must be an allowlisted internal recipe.", "Choose an allowlisted recipe and retry."));
  if (desiredAttempts < 1 || desiredAttempts > 32) return runError(new RunRequestError("run_attempts_invalid", "desiredAttempts must be between 1 and 32.", "Set desiredAttempts between 1 and 32 and retry."));
  const providerRouting = parseProviderRouting(body);
  if (providerRouting instanceof Response) return providerRouting;
  return {
    source: { repository, ref: typeof source?.ref === "string" ? source.ref.trim() : undefined, commit },
    recipe,
    desiredAttempts,
    provider: providerRouting.provider,
    routing: providerRouting.routing,
  };
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/runs",
    { "cmux.vm.operation": "run_create" },
    "/api/runs POST failed",
    async ({ user }) => {
      let body: Record<string, unknown> | null;
      try {
        body = jsonBodyObject(await request.json());
      } catch {
        body = null;
      }
      if (!body) return runError(new RunRequestError("run_invalid_request", "Run body must be a JSON object.", "Send a JSON object and retry."));
      const parsed = parseCreateRunBody(body);
      if (parsed instanceof Response) return parsed;
      const idempotencyKey = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim() || "";
      if (!idempotencyKey || idempotencyKey.length > 128) return runError(new RunRequestError("run_idempotency_required", "Idempotency-Key is required for Run creation.", "Add an Idempotency-Key header and retry."));
      const scope = await resolveVmProvisioningAccountScope(user, request);
      if (!scope.ok) return scope.response;
      if (parsed.routing.requestedProvider === "huge-blue") {
        return runError(new RunRequestError("run_provider_unavailable", "The Huge Blue Run adapter is not configured for this deployment.", "Choose the freestyle provider and retry.", 409, { reasonCode: "adapter_not_configured" }));
      }
      if (parsed.routing.requestedProvider === "unknown") {
        return runError(new RunRequestError("run_provider_invalid", "The requested Run provider is not recognized.", "Choose a supported Run provider and retry.", 400, { reasonCode: "provider_unknown" }));
      }
      try {
        const admitted = await createRunWithAllocationAdmission({
          request,
          billingTeamId: scope.entitlements.billingTeamId,
          run: {
            userId: user.id,
            billingTeamId: scope.entitlements.billingTeamId,
            idempotencyKey,
            requestDigest: requestDigest(parsed),
            source: parsed.source,
            recipe: parsed.recipe,
            provider: parsed.provider,
            desiredAttempts: parsed.desiredAttempts,
          },
        });
        if (admitted.kind === "limited") return admitted.response;
        const run = admitted.run;
        runAfterResponse(async () => {
          await launchQueuedCloudVmAttempts({
            user,
            entitlements: scope.entitlements,
            runId: run.run.id,
            attempts: run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status })),
            source: run.run.source,
            recipe: run.run.recipe,
          });
        });
        const accountClass = scope.entitlements.billingCustomerType === "team" ? "team" : "personal";
        return runJson({
          id: run.run.id,
          status: run.run.status,
          attempts: run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status })),
          createdAt: run.run.createdAt,
          executionProvider: "cloud-vm",
          backendProvider: "freestyle",
          routing: runRoutingFor({ routing: parsed.routing, backendProvider: "freestyle", accountClass }),
          admission: runAdmissionFor({ backendProvider: "freestyle", accountEligible: true, limits: { maxActiveSessions: scope.entitlements.maxActiveVms } }),
        }, 202);
      } catch (error) {
        return runError(error);
      }
    },
  );
}

