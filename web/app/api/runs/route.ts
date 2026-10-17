import { resolveVmProvisioningAccountScope, runAfterResponse, withAuthedVmApiRoute } from "../../../services/vms/routeHelpers";
import { runError, runJson, jsonBodyObject } from "../../../services/runs/http";
import { createRun, requestDigest } from "../../../services/runs/repository";
import { launchQueuedCloudVmAttempts } from "../../../services/runs/dogfood";
import { ALLOWED_RUN_RECIPES, type RunRoutingRequest, type RunVariantRecipe } from "../../../services/runs/model";
import { runAdmissionFor, runRoutingFor } from "../../../services/runs/view";

export const maxDuration = 960;

type ParsedRunBody = {
  readonly source: { readonly repository?: string; readonly ref?: string; readonly commit: string };
  readonly recipe: string;
  readonly desiredAttempts: number;
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
  readonly variants: readonly RunVariantRecipe[];
};

type ParsedProviderRouting = {
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
};

function parseProviderRouting(body: Record<string, unknown>): ParsedProviderRouting | Response {
  if (body.provider !== undefined && body.provider !== "cloud-vm") return runJson({ error: "run_provider_invalid", message: "The MVP provider is cloud-vm." }, 400);
  const routingBody = jsonBodyObject(body.routing);
  const requestedProvider = routingBody?.requestedProvider;
  if (requestedProvider !== undefined && requestedProvider !== "freestyle" && requestedProvider !== "huge-blue" && requestedProvider !== "unknown") {
    return runJson({ error: "run_provider_invalid", message: "routing.requestedProvider must be freestyle, huge-blue, or unknown." }, 400);
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
  const rawVariants = Array.isArray(body.variants) ? body.variants : [];
  const variants = rawVariants.map((value, index) => {
    const candidate = jsonBodyObject(value);
    return {
      id: typeof candidate?.id === "string" ? candidate.id.trim() : `attempt-${index + 1}`,
      label: typeof candidate?.label === "string" ? candidate.label.trim() : `Attempt ${String.fromCharCode(65 + index)}`,
      instruction: typeof candidate?.instruction === "string" ? candidate.instruction.trim() : "Explore the shared intent independently and publish build, test, and artifact evidence.",
    } satisfies RunVariantRecipe;
  });
  if (variants.length === 0 && desiredAttempts > 0) {
    variants.push(...Array.from({ length: desiredAttempts }, (_, index) => ({
      id: `attempt-${index + 1}`,
      label: `Attempt ${String.fromCharCode(65 + index)}`,
      instruction: "Explore the shared intent independently and publish build, test, and artifact evidence.",
    })));
  }
  if (!/^[0-9a-f]{40}$/i.test(commit)) return runJson({ error: "run_source_required", message: "source.commit must be a 40-character immutable commit SHA." }, 400);
  if (!repository || repository.length > 512) return runJson({ error: "run_source_required", message: "source.repository is required." }, 400);
  if (!ALLOWED_RUN_RECIPES.includes(recipe as (typeof ALLOWED_RUN_RECIPES)[number])) return runJson({ error: "run_recipe_required", message: "recipe must be an allowlisted internal recipe." }, 400);
  if (desiredAttempts < 1 || desiredAttempts > 32) return runJson({ error: "run_attempts_invalid", message: "desiredAttempts must be between 1 and 32." }, 400);
  if (variants.length !== desiredAttempts) return runJson({ error: "run_variants_invalid", message: "variants must contain one recipe for each desired attempt." }, 400);
  if (variants.some((variant) => !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(variant.id) || variant.label.length === 0 || variant.label.length > 120 || variant.instruction.length === 0 || variant.instruction.length > 8_192)) {
    return runJson({ error: "run_variants_invalid", message: "Each variant needs a unique safe id, label, and bounded instruction." }, 400);
  }
  const providerRouting = parseProviderRouting(body);
  if (providerRouting instanceof Response) return providerRouting;
  return {
    source: { repository, ref: typeof source?.ref === "string" ? source.ref.trim() : undefined, commit },
    recipe,
    desiredAttempts,
    provider: providerRouting.provider,
    routing: providerRouting.routing,
    variants,
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
      if (!body) return runJson({ error: "run_invalid_request", message: "Run body must be a JSON object." }, 400);
      const parsed = parseCreateRunBody(body);
      if (parsed instanceof Response) return parsed;
      const idempotencyKey = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim() || "";
      if (!idempotencyKey || idempotencyKey.length > 128) return runJson({ error: "run_idempotency_required", message: "Idempotency-Key is required for Run creation." }, 400);
      const scope = await resolveVmProvisioningAccountScope(user, request);
      if (!scope.ok) return scope.response;
      if (parsed.routing.requestedProvider === "huge-blue") {
        return runJson({
          error: "run_provider_unavailable",
          reasonCode: "adapter_not_configured",
          message: "The Huge Blue Run adapter is not configured for this deployment.",
          retryable: false,
        }, 409);
      }
      if (parsed.routing.requestedProvider === "unknown") {
        return runJson({
          error: "run_provider_invalid",
          reasonCode: "provider_unknown",
          message: "The requested Run provider is not recognized.",
          retryable: false,
        }, 400);
      }
      try {
        const run = await createRun({
          userId: user.id,
          billingTeamId: scope.entitlements.billingTeamId,
          idempotencyKey,
          requestDigest: requestDigest(parsed),
          source: parsed.source,
          recipe: parsed.recipe,
          provider: parsed.provider,
          desiredAttempts: parsed.desiredAttempts,
          variants: parsed.variants,
        });
        runAfterResponse(async () => {
          await launchQueuedCloudVmAttempts({
            user,
            entitlements: scope.entitlements,
            runId: run.run.id,
            attempts: run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status, variant: attempt.variant })),
            source: run.run.source,
            recipe: run.run.recipe,
          });
        });
        const accountClass = scope.entitlements.billingCustomerType === "team" ? "team" : "personal";
        return runJson({
          id: run.run.id,
          status: run.run.status,
          attempts: run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status, variant: attempt.variant })),
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

