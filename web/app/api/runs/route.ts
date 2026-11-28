import {
  jsonResponse,
  vmErrorResponse,
  withAuthedVmApiRoute,
} from "../../../services/vms/routeHelpers";
import { createRunRecord, listRunSnapshots, markAttemptFailed, markAttemptRunning, markAttemptSucceeded, readRunSnapshot, RunIdempotencyConflictError } from "../../../services/runs/repository";
import { normalizeRunSpec, runSpecDigest, type RunSpec } from "../../../services/runs/spec";
import { assertFreestyleSource, parseSourceVerificationReceipt, sourceVerificationCommand } from "../../../services/runs/sourceVerification";

type CreatedRun = Awaited<ReturnType<typeof createRunRecord>>;
type RunAttempt = CreatedRun["snapshot"]["attempts"][number];

type AttemptSuccess = {
  readonly ok: true;
  readonly providerVmId: string;
  readonly vmBody: unknown;
  readonly result: Record<string, unknown>;
};

type AttemptFailure = { readonly ok: false; readonly response: Response };


function safeError(error: unknown): string {
  const source = error && typeof error === "object" ? error as Record<string, unknown> : {};
  const cause = source.cause && typeof source.cause === "object" ? source.cause as Record<string, unknown> : undefined;
  const message = typeof cause?.message === "string" ? cause.message : typeof source.message === "string" ? source.message : String(error);
  const fields = ["detail", "constraint", "column", "table", "schema", "hint"]
    .map((key) => typeof cause?.[key] === "string" ? `${key}=${cause[key]}` : "")
    .filter(Boolean)
    .join("; ");
  const code = typeof cause?.code === "string" ? ` [${cause.code}]` : "";
  return `${message}${fields ? ` (${fields})` : ""}${code}`.replace(/(?:postgres(?:ql)?:\/\/)[^\s]+/gi, "postgres://<redacted>").slice(0, 1_000);
}

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
    const spec = normalizeRunSpec(candidate);
    assertFreestyleSource(spec);
    return spec;
  } catch (error) {
    return errorResponse(error instanceof Error ? error.message : "RunSpec validation failed.");
  }
}

function forwardedHeaders(request: Request, key?: string): Headers {
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  headers.set("content-type", "application/json");
  if (key) headers.set("idempotency-key", key);
  return headers;
}

async function responseBody(response: Response): Promise<Record<string, unknown> | null> {
  try {
    return bodyObject(await response.clone().json());
  } catch {
    return null;
  }
}

async function runReceipt(runId: string, userId: string, status = 502): Promise<Response> {
  return jsonResponse(receipt(await readRunSnapshot(runId, userId)), status);
}

async function provisionVm(request: Request, userId: string, spec: RunSpec, runId: string, attemptId: string): Promise<AttemptSuccess | AttemptFailure> {
  const vmRequest = new Request(new URL("/api/vm", request.url), {
    method: "POST",
    headers: forwardedHeaders(request, `run:${runId}:attempt:${attemptId}`),
    body: JSON.stringify({
      provider: "freestyle",
      displayName: `run-${runId.slice(0, 8)}`,
      ...(spec.workspace.kind === "persistent" ? { persistentHome: true } : {}),
    }),
  });
  const vmResponse = await fetch(vmRequest);
  const vmBody = await responseBody(vmResponse);
  if (!vmResponse.ok) {
    const message = vmBody?.message;
    await markAttemptFailed({ runId, attemptId, error: typeof message === "string" ? message : `Cloud VM create failed (${vmResponse.status}).` });
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  const providerVmId = typeof vmBody?.id === "string" ? vmBody.id : null;
  if (!providerVmId) {
    await markAttemptFailed({ runId, attemptId, error: "Cloud VM create returned no provider id." });
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  return {
    ok: true,
    providerVmId,
    vmBody,
    result: {
      provider: typeof vmBody?.provider === "string" ? vmBody.provider : "freestyle",
      image: typeof vmBody?.image === "string" ? vmBody.image : undefined,
      createdAt: typeof vmBody?.createdAt === "string" ? vmBody.createdAt : undefined,
    },
  };
}

async function destroyVmForAttempt(request: Request, providerVmId: string): Promise<Response> {
  return fetch(new Request(new URL(`/api/vm/${encodeURIComponent(providerVmId)}`, request.url), { method: "DELETE", headers: request.headers }));
}

async function executeAttempt(request: Request, userId: string, runId: string, attemptId: string, providerVmId: string, result: Record<string, unknown>, spec: RunSpec): Promise<{ ok: true; result: Record<string, unknown> } | AttemptFailure> {
  const marker = `${runId}:${attemptId}:completed`;
  let command: string;
  try {
    command = sourceVerificationCommand(spec, marker);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Run source verification could not be prepared.";
    await markAttemptFailed({ runId, attemptId, error: message });
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  const execRequest = new Request(new URL(`/api/vm/${encodeURIComponent(providerVmId)}/exec`, request.url), {
    method: "POST",
    headers: forwardedHeaders(request),
    body: JSON.stringify({ command, timeoutMs: 60_000 }),
  });
  const execResponse = await fetch(execRequest);
  const execOutput = await responseBody(execResponse);
  if (!execResponse.ok || typeof execOutput?.stdout !== "string" || !execOutput.stdout.includes(marker)) {
    const message = typeof execOutput?.message === "string" ? execOutput.message : `Cloud Run command failed (${execResponse.status}).`;
    await markAttemptFailed({ runId, attemptId, error: message });
    await destroyVmForAttempt(request, providerVmId).catch(() => undefined);
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  let sourceReceipt;
  try {
    sourceReceipt = parseSourceVerificationReceipt(execOutput.stdout, spec);
  } catch (error) {
    const message = error instanceof Error ? error.message : "Cloud Run source verification receipt was invalid.";
    await markAttemptFailed({ runId, attemptId, error: message });
    await destroyVmForAttempt(request, providerVmId).catch(() => undefined);
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  const cleanupResponse = await destroyVmForAttempt(request, providerVmId);
  if (!cleanupResponse.ok) {
    await markAttemptFailed({ runId, attemptId, error: `Cloud Run cleanup failed (${cleanupResponse.status}).` });
    return { ok: false, response: await runReceipt(runId, userId) };
  }
  return {
    ok: true,
    result: {
      ...result,
      sourceReceipt,
      commandReceipt: { commandDigest: runSpecDigest(spec), stdout: execOutput.stdout },
    },
  };
}

async function createOrReuseRun(request: Request, user: { id: string; billingTeamId?: string | null }, key: string, spec: RunSpec): Promise<CreatedRun | Response> {
  try {
    return await createRunRecord({ userId: user.id, billingTeamId: user.billingTeamId || null, idempotencyKey: key, requestDigest: runSpecDigest(spec), spec });
  } catch (error) {
    if (error instanceof RunIdempotencyConflictError) return errorResponse("Idempotency-Key was already used for a different RunSpec.", 409);
    throw error;
  }
}

async function executeNewRun(request: Request, user: { id: string }, created: CreatedRun, spec: RunSpec): Promise<Response> {
  const attempt = created.snapshot.attempts[0];
  if (!attempt) throw new Error("Run did not create an attempt");
  const runId = created.snapshot.run.id;
  await markAttemptRunning(runId, attempt.id);
  const provisioned = await provisionVm(request, user.id, spec, runId, attempt.id);
  if (!provisioned.ok) return provisioned.response;
  const executed = await executeAttempt(request, user.id, runId, attempt.id, provisioned.providerVmId, provisioned.result, spec);
  if (!executed.ok) return executed.response;
  await markAttemptSucceeded({ runId, attemptId: attempt.id, providerVmId: provisioned.providerVmId, result: executed.result });
  return jsonResponse({ ...receipt(await readRunSnapshot(runId, user.id)), vm: provisioned.vmBody }, 201);
}

/** Create one durable Run and provision its first cloud-vm attempt. */
export async function POST(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs", { "cmux.vm.operation": "run.create" }, "/api/runs POST failed", async ({ user }) => {
    const key = idempotencyKey(request);
    if (!key) return errorResponse("Idempotency-Key is required for a Run.");
    const spec = await parseSpec(request);
    if (spec instanceof Response) return spec;
    try {
      const created = await createOrReuseRun(request, user, key, spec);
      if (created instanceof Response) return created;
      if (created.reused) return jsonResponse(receipt(created.snapshot), 200);
      return await executeNewRun(request, user, created, spec);
    } catch (error) {
      return vmErrorResponse({
        error: "run_execution_failed",
        status: 502,
        message: safeError(error),
        action: "Retry the same Idempotency-Key to replay the durable Run receipt.",
      });
    }
  });
}

/** List the caller's latest durable Runs. Use /api/runs/:id for one receipt. */
export async function GET(request: Request): Promise<Response> {
  return withAuthedVmApiRoute(request, "/api/runs", { "cmux.vm.operation": "run.list" }, "/api/runs GET failed", async ({ user }) => jsonResponse({ runs: (await listRunSnapshots(user.id)).map(receipt) }));
}

export const maxDuration = 960;
