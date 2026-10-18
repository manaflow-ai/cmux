import { POST as createVm } from "../vm/route";
import { POST as execVmRoute } from "../vm/[id]/exec/route";
import { DELETE as deleteVm } from "../vm/[id]/route";
import {
  jsonResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { createRunRecord, listRunSnapshots, markAttemptFailed, markAttemptRunning, markAttemptSucceeded, readRunSnapshot, RunIdempotencyConflictError } from "../../../services/runs/repository";
import { normalizeRunSpec, runSpecDigest, type RunSpec } from "../../../services/runs/spec";

function errorResponse(message: string, status = 400): Response {
  return vmErrorResponse({
    error: status === 409 ? "run_idempotency_conflict" : "run_invalid_request",
    status,
    message,
    action: status === 409 ? "Use the original Idempotency-Key for this Run, or choose a new key." : "Send a valid cmux.run/v1 RunSpec.",
  });
}

function idempotencyKey(request: Request): string | null {
  const value = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim();
  return value ? value.slice(0, 128) : null;
}

function bodyObject(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

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

async function parseSpec(request: Request): Promise<RunSpec | Response> {
  let raw: unknown;
  try {
    raw = await request.json();
  } catch {
    return errorResponse("Run API expected valid JSON.");
  }
  const object = bodyObject(raw);
  const candidate = object && "spec" in object ? object.spec : raw;
  try {
    return normalizeRunSpec(candidate);
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "RunSpec validation failed.");
  }
}

/**
 * Create one durable Run and provision its first cloud-vm attempt through the
 * existing authenticated VM lifecycle. Additional variants remain queued for
 * the fan-out worker; this first slice keeps the synchronous path bounded.
 */
export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/runs",
    { "cmux.vm.operation": "run.create" },
    "/api/runs POST failed",
    async ({ user }) => {
      const key = idempotencyKey(request);
      if (!key) return errorResponse("Idempotency-Key is required for a Run.");
      const parsed = await parseSpec(request);
      if (parsed instanceof Response) return parsed;
      const spec = parsed;
      const requestDigest = runSpecDigest(spec);
      let created: Awaited<ReturnType<typeof createRunRecord>>;
      try {
        created = await createRunRecord({
          userId: user.id,
          billingTeamId: user.billingTeamId || null,
          idempotencyKey: key,
          requestDigest,
          spec,
        });
      } catch (error) {
        if (error instanceof RunIdempotencyConflictError) return errorResponse("Idempotency-Key was already used for a different RunSpec.", 409);
        throw error;
      }
      if (created.reused) return jsonResponse(receipt(created.snapshot), 200);
      const attempt = created.snapshot.attempts[0];
      if (!attempt) throw new Error("Run did not create an attempt");
      await markAttemptRunning(created.snapshot.run.id, attempt.id);

      const vmHeaders = new Headers(request.headers);
      vmHeaders.delete("content-length");
      vmHeaders.delete("transfer-encoding");
      vmHeaders.set("content-type", "application/json");
      vmHeaders.set("idempotency-key", `run:${created.snapshot.run.id}:attempt:${attempt.id}`);
      const vmRequest = new Request(new URL("/api/vm", request.url), {
        method: "POST",
        headers: vmHeaders,
        body: JSON.stringify({
          provider: "freestyle",
          displayName: `run-${created.snapshot.run.id.slice(0, 8)}`,
          ...(spec.workspace.kind === "persistent" ? { persistentHome: true } : {}),
        }),
      });
      const vmResponse = await createVm(vmRequest);
      let vmBody: unknown = null;
      try { vmBody = await vmResponse.clone().json(); } catch { /* Preserve a stable error below. */ }
      if (!vmResponse.ok) {
        const message = bodyObject(vmBody)?.message;
        await markAttemptFailed({ runId: created.snapshot.run.id, attemptId: attempt.id, error: typeof message === "string" ? message : `Cloud VM create failed (${vmResponse.status}).` });
        return jsonResponse(receipt(await readRunSnapshot(created.snapshot.run.id, user.id)), 502);
      }
      const vm = bodyObject(vmBody);
      const providerVmId = typeof vm?.id === "string" ? vm.id : null;
      if (!providerVmId) {
        await markAttemptFailed({ runId: created.snapshot.run.id, attemptId: attempt.id, error: "Cloud VM create returned no provider id." });
        return jsonResponse(receipt(await readRunSnapshot(created.snapshot.run.id, user.id)), 502);
      }
      const result = {
        provider: typeof vm?.provider === "string" ? vm.provider : "freestyle",
        image: typeof vm?.image === "string" ? vm.image : undefined,
        createdAt: typeof vm?.createdAt === "string" ? vm.createdAt : undefined,
      } satisfies Record<string, unknown>;
      // The first Cloud Run slice owns a bounded command lifecycle: create the
      // provider VM through the existing authenticated route, execute one
      // receipt-producing command through the same tenant-scoped route, then
      // destroy it before declaring the attempt terminal. This keeps provider
      // credentials and cleanup policy inside cmux Cloud.
      const command = `printf 'cmux-run:${created.snapshot.run.id}:${attempt.id}:completed\\n'`;
      const execHeaders = new Headers(request.headers);
      execHeaders.delete("content-length");
      execHeaders.delete("transfer-encoding");
      execHeaders.set("content-type", "application/json");
      const execRequest = new Request(new URL(`/api/vm/${encodeURIComponent(providerVmId)}/exec`, request.url), {
        method: "POST",
        headers: execHeaders,
        body: JSON.stringify({ command, timeoutMs: 60_000 }),
      });
      const execResponse = await execVmRoute(execRequest, { params: Promise.resolve({ id: providerVmId }) });
      let execBody: unknown = null;
      try { execBody = await execResponse.clone().json(); } catch { /* Preserve a stable error below. */ }
      const execOutput = bodyObject(execBody);
      if (!execResponse.ok || typeof execOutput?.stdout !== "string" || !execOutput.stdout.includes(`${created.snapshot.run.id}:${attempt.id}:completed`)) {
        const message = typeof execOutput?.message === "string" ? execOutput.message : `Cloud Run command failed (${execResponse.status}).`;
        await markAttemptFailed({ runId: created.snapshot.run.id, attemptId: attempt.id, error: message });
        await deleteVm(new Request(new URL(`/api/vm/${encodeURIComponent(providerVmId)}`, request.url), { method: "DELETE", headers: request.headers }), { params: Promise.resolve({ id: providerVmId }) }).catch(() => undefined);
        return jsonResponse(receipt(await readRunSnapshot(created.snapshot.run.id, user.id)), 502);
      }
      const cleanupResponse = await deleteVm(new Request(new URL(`/api/vm/${encodeURIComponent(providerVmId)}`, request.url), { method: "DELETE", headers: request.headers }), { params: Promise.resolve({ id: providerVmId }) });
      if (!cleanupResponse.ok) {
        const message = `Cloud Run cleanup failed (${cleanupResponse.status}).`;
        await markAttemptFailed({ runId: created.snapshot.run.id, attemptId: attempt.id, error: message });
        return jsonResponse(receipt(await readRunSnapshot(created.snapshot.run.id, user.id)), 502);
      }
      result.commandReceipt = { commandDigest: runSpecDigest(spec), stdout: execOutput.stdout };
      await markAttemptSucceeded({ runId: created.snapshot.run.id, attemptId: attempt.id, providerVmId, result });
      const finalSnapshot = await readRunSnapshot(created.snapshot.run.id, user.id);
      return jsonResponse({
        ...receipt(finalSnapshot),
        vm: vmBody,
      }, 201);
    },
  );
}

/** List the caller's latest durable Runs. Use /api/runs/:id for one receipt. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/runs",
    { "cmux.vm.operation": "run.list" },
    "/api/runs GET failed",
    async ({ user }) => jsonResponse({ runs: (await listRunSnapshots(user.id)).map(receipt) }),
  );
}

export const maxDuration = 960;
