import { runArtifactResponse, RunArtifactIntegrityError } from "../../../../../../services/runs/legacy/artifactContent";
import { withRunRoute, RunHttpError, runNotFound, validRunId } from "../../../../../../services/runs/legacy/http";
import { readRunArtifact } from "../../../../../../services/runs/legacy/repository";

/** Download an immutable JSON receipt through the same team/user ACL as its owning Run. */
export function GET(
  request: Request,
  context: { params: Promise<{ id: string; artifactId: string }> },
): Promise<Response> {
  return withRunRoute(request, "/api/runs/:id/artifacts/:artifactId", async (scope) => {
    const { id, artifactId } = await context.params;
    const row = await readRunArtifact({
      ...scope,
      runId: validRunId(id),
      artifactId: validRunId(artifactId),
    });
    if (!row) runNotFound();
    try {
      return runArtifactResponse(row);
    } catch (error) {
      if (error instanceof RunArtifactIntegrityError)
        throw new RunHttpError(409, "run_artifact_integrity", "Stored Run artifact bytes could not be verified");
      throw error;
    }
  });
}
