import { runError, runJson, jsonBodyObject, RunRequestError, RunUnauthorizedError } from "../../../../../../../services/runs/http";
import { ingestRunEvent } from "../../../../../../../services/runs/repository";
import { isRunWorkerAuthorized } from "../../../../../../../services/runs/workerAuth";
import { RUN_EVENT_KINDS, type RunEventKind } from "../../../../../../../services/runs/model";

export async function POST(request: Request, { params }: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  const scope = await params;
  if (!isRunWorkerAuthorized(request, { runId: scope.id, attemptId: scope.attemptId })) return runError(new RunUnauthorizedError());
  const parsed = jsonBodyObject(await request.json().catch(() => null));
  if (!parsed || typeof parsed.leaseToken !== "string" || typeof parsed.leaseGeneration !== "number" || typeof parsed.externalId !== "string" || typeof parsed.attemptSequence !== "number" || typeof parsed.kind !== "string" || !RUN_EVENT_KINDS.includes(parsed.kind as RunEventKind) || !parsed.kind.startsWith("attempt.")) return runError(new RunRequestError("run_event_invalid", "Lease, externalId, attemptSequence, and a supported attempt kind are required.", "Provide valid event fields and retry."));
  const { id, attemptId } = scope;
  try {
    const event = await ingestRunEvent({ runId: id, attemptId, leaseToken: parsed.leaseToken, leaseGeneration: parsed.leaseGeneration, externalId: parsed.externalId, attemptSequence: parsed.attemptSequence, kind: parsed.kind as RunEventKind, payload: jsonBodyObject(parsed.payload) ?? {} });
    return runJson({ event });
  } catch (error) {
    return runError(error);
  }
}

