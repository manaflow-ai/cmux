import { after } from "next/server";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import { withRunRoute, RunHttpError } from "../../../services/runs/http";
import { createRunRecord, listRunSnapshots, RunAdmissionError, RunIdempotencyConflictError } from "../../../services/runs/repository";
import { normalizeRunSpec, RunSpecValidationError, runSpecDigest } from "../../../services/runs/spec";
import { assertFreestyleSource } from "../../../services/runs/sourceVerification";
import { runReceipt } from "../../../services/runs/view";
import { processRunQueue } from "../../../services/runs/runner";

function validateSupportedSpec(spec: ReturnType<typeof normalizeRunSpec>) {
      assertFreestyleSource(spec);
      if (spec.routing.backend === "huge-blue") throw new Error("Huge Blue is unavailable");
      if (spec.capabilities.secretRefs.length || spec.capabilities.networkProfile || spec.source.imageDigest) throw new Error("This recipe does not support custom capabilities or image digests");
      if (spec.resources.spendCap !== null || spec.resources.cpuClass !== "standard" || spec.resources.memoryClass !== "standard") throw new Error("Custom resource classes and spend caps require a matching provider admission policy");
      if (spec.recipe.id !== "cloud-vm-dogfood" && spec.variants.some((variant) => !variant.instruction)) throw new Error("Each agent variant requires an instruction and its digest");
}
export const maxDuration = 960;
export function POST(request: Request): Promise<Response> {
  return withRunRoute(request, "/api/runs", async (scope) => {
    const key = request.headers.get("idempotency-key")?.trim();
    if (!key || key.length > 128) throw new RunHttpError(400, "invalid_idempotency_key", "Idempotency-Key must contain 1-128 characters");
    const body = await request.json().catch(() => { throw new RunHttpError(400, "invalid_json", "Expected JSON"); });
    let spec;
    try {
      spec = normalizeRunSpec(body.spec ?? body);
      validateSupportedSpec(spec);
    } catch (error) {
      throw new RunHttpError(400, "run_invalid_spec", error instanceof Error ? error.message : "Invalid RunSpec");
    }
    try {
      const created = await createRunRecord({ ...scope, billingTeamId: scope.ownerTeamId, idempotencyKey: key, requestDigest: runSpecDigest(spec), spec });
      // This is an acceleration only. The durable queue and protected cron own
      // recovery if the request/process disappears after the 202 response.
      after(() => processRunQueue({ runId: created.snapshot.run.id, ownerTeamId: scope.ownerTeamId }));
      return jsonResponse(runReceipt(created.snapshot), created.reused ? 200 : 202);
    } catch (error) {
      if (error instanceof RunIdempotencyConflictError) throw new RunHttpError(409, "run_idempotency_conflict", error.message);
      if (error instanceof RunAdmissionError) throw new RunHttpError(429, "run_admission_full", error.message);
      if (error instanceof RunSpecValidationError) throw new RunHttpError(400, "run_invalid_spec", error.message);
      throw error;
    }
  });
}
export function GET(request: Request): Promise<Response> {
  return withRunRoute(request, "/api/runs", async (scope) => jsonResponse({ runs: (await listRunSnapshots(scope)).map(runReceipt) }));
}
