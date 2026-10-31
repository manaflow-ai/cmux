import { runError, runJson, jsonBodyObject, RunUnauthorizedError } from "../../../../../../../services/runs/http";
import { claimAttemptLease, renewAttemptLease } from "../../../../../../../services/runs/repository";
import { isRunWorkerAuthorized } from "../../../../../../../services/runs/workerAuth";

export async function POST(request: Request, { params }: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  const scope = await params;
  if (!isRunWorkerAuthorized(request, { runId: scope.id, attemptId: scope.attemptId })) return runError(new RunUnauthorizedError());
  const body = await request.json().catch(() => null);
  const parsed = jsonBodyObject(body) ?? {};
  const { id, attemptId } = scope;
  try {
    if (typeof parsed.leaseToken === "string" && typeof parsed.leaseGeneration === "number") {
      const lease = await renewAttemptLease({ runId: id, attemptId, leaseToken: parsed.leaseToken, leaseGeneration: parsed.leaseGeneration, ttlMs: typeof parsed.ttlMs === "number" ? parsed.ttlMs : undefined });
      return runJson({ leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration, leaseExpiresAt: lease.leaseExpiresAt, attempt: lease.attempt });
    }
    const lease = await claimAttemptLease({ runId: id, attemptId, workerId: typeof parsed.workerId === "string" ? parsed.workerId : "worker", ttlMs: typeof parsed.ttlMs === "number" ? parsed.ttlMs : undefined });
    return runJson({ leaseToken: lease.leaseToken, leaseGeneration: lease.leaseGeneration, leaseExpiresAt: lease.leaseExpiresAt, attempt: lease.attempt });
  } catch (error) {
    return runError(error);
  }
}

