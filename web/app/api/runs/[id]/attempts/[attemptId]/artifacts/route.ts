import { runError, runJson, jsonBodyObject, RunRequestError, RunUnauthorizedError } from "../../../../../../../services/runs/http";
import { recordRunArtifact } from "../../../../../../../services/runs/repository";
import { isRunWorkerAuthorized } from "../../../../../../../services/runs/workerAuth";

export async function POST(request: Request, { params }: { params: Promise<{ id: string; attemptId: string }> }): Promise<Response> {
  const scope = await params;
  if (!isRunWorkerAuthorized(request, { runId: scope.id, attemptId: scope.attemptId })) return runError(new RunUnauthorizedError());
  const parsed = jsonBodyObject(await request.json().catch(() => null));
  if (!parsed || typeof parsed.leaseToken !== "string" || typeof parsed.leaseGeneration !== "number" || typeof parsed.name !== "string" || typeof parsed.sizeBytes !== "number" || typeof parsed.digest !== "string" || typeof parsed.uri !== "string") return runError(new RunRequestError("run_artifact_invalid", "Lease and artifact manifest fields are required.", "Provide the lease and artifact manifest fields, then retry."));
  const { id, attemptId } = scope;
  try {
    const artifact = await recordRunArtifact({ runId: id, attemptId, leaseToken: parsed.leaseToken, leaseGeneration: parsed.leaseGeneration, name: parsed.name, sizeBytes: parsed.sizeBytes, digest: parsed.digest, uri: parsed.uri, mediaType: typeof parsed.mediaType === "string" ? parsed.mediaType : undefined, metadata: jsonBodyObject(parsed.metadata) ?? undefined });
    return runJson({ artifact }, 201);
  } catch (error) {
    return runError(error);
  }
}

