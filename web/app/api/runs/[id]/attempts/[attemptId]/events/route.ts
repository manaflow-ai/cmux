import { runError, runJson, jsonBodyObject } from "../../../../../../../services/runs/http";
import { ingestRunEvent } from "../../../../../../../services/runs/repository";
import { isRunWorkerAuthorized } from "../../../../../../../services/runs/workerAuth";
import { RUN_EVENT_KINDS, type RunEventKind } from "../../../../../../../services/runs/model";

export async function POST(request: Request, { params }: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  const scope = await params;
  if (!isRunWorkerAuthorized(request, { runId: scope.id, attemptId: scope.attemptId })) return runJson({ error: "unauthorized" }, 401);
  const parsed = jsonBodyObject(await request.json().catch(() => null));
  if (!parsed || typeof parsed.leaseToken !== "string" || typeof parsed.leaseGeneration !== "number" || typeof parsed.externalId !== "string" || typeof parsed.attemptSequence !== "number" || typeof parsed.kind !== "string" || !RUN_EVENT_KINDS.includes(parsed.kind as RunEventKind) || !parsed.kind.startsWith("attempt.")) return runJson({ error: "run_event_invalid", message: "lease, eventId, attemptSequence, and a supported attempt kind are required." }, 400);
  const { id, attemptId } = scope;
  try {
    const event = await ingestRunEvent({ runId: id, attemptId, leaseToken: parsed.leaseToken, leaseGeneration: parsed.leaseGeneration, externalId: parsed.externalId, attemptSequence: parsed.attemptSequence, kind: parsed.kind as RunEventKind, payload: jsonBodyObject(parsed.payload) ?? {} });
    return runJson({ event });
  } catch (error) {
    return runError(error);
  }
}

