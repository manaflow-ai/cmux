import { jsonResponse, vmErrorResponse, withAuthedVmApiRoute } from "../../../../services/vms/routeHelpers";
import { readRunSnapshot } from "../../../../services/runs/repository";

function receipt(snapshot: Awaited<ReturnType<typeof readRunSnapshot>>) {
  if (!snapshot) return null;
  return {
    id: snapshot.run.id,
    status: snapshot.run.status,
    provider: snapshot.run.provider,
    requestDigest: snapshot.run.requestDigest,
    desiredAttempts: snapshot.run.desiredAttempts,
    createdAt: snapshot.run.createdAt,
    updatedAt: snapshot.run.updatedAt,
    completedAt: snapshot.run.completedAt,
    attempts: snapshot.attempts.map((attempt) => ({
      id: attempt.id,
      ordinal: attempt.ordinal,
      status: attempt.status,
      variant: attempt.variant,
      providerVmId: attempt.providerVmId,
      result: attempt.result,
      error: attempt.error,
      startedAt: attempt.startedAt,
      finishedAt: attempt.finishedAt,
    })),
    events: snapshot.events.map((event) => ({
      id: event.id,
      attemptId: event.attemptId,
      sequence: event.sequence,
      kind: event.kind,
      payload: event.payload,
      createdAt: event.createdAt,
    })),
  };
}

export async function GET(request: Request, context: { params: Promise<{ id: string }> }): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/runs/:id",
    { "cmux.vm.operation": "run.read" },
    "/api/runs/:id GET failed",
    async ({ user }) => {
      const { id } = await context.params;
      if (!/^[0-9a-f-]{36}$/i.test(id)) {
        return vmErrorResponse({ error: "run_not_found", status: 404, message: "Run not found.", action: "Check the Run id and try again." });
      }
      const snapshot = await readRunSnapshot(id, user.id);
      if (!snapshot) {
        return vmErrorResponse({ error: "run_not_found", status: 404, message: "Run not found.", action: "Check the Run id and try again." });
      }
      return jsonResponse(receipt(snapshot));
    },
  );
}

