import { resolveVmProvisioningAccountScope, runAfterResponse, withAuthedVmApiRoute } from "../../../services/vms/routeHelpers";
import { runError, runJson, jsonBodyObject, RunRequestError } from "../../../services/runs/http";
import { findRunByIdempotencyKey, getRun, requestDigest, type RunSource } from "../../../services/runs/repository";
import { launchQueuedCloudVmAttempts, launchSandboxRun } from "../../../services/runs/dogfood";
import {
  ALLOWED_RUN_RECIPES,
  SANDBOX_DEFAULT_TIMEOUT_MS,
  SANDBOX_MAX_TIMEOUT_MS,
  SANDBOX_MIN_TIMEOUT_MS,
  SANDBOX_RUN_RECIPE,
  SANDBOX_TASK_MAX_CHARS,
  type RunRoutingRequest,
} from "../../../services/runs/model";
import { CLOUD_VM_AGENTS, type CloudVmAgent } from "../../../services/vms/cloudVmRunAdapter";
import { defaultProviderId } from "../../../services/vms/drivers";
import { isVmImageConfigError } from "../../../services/vms/errors";
import { findVmImageManifestEntry, resolveVmImage, type VmImageSelection } from "../../../services/vms/images/resolver";
import { runAdmissionFor, runRoutingFor } from "../../../services/runs/view";
import { createRunWithAllocationAdmission } from "../../../services/runs/allocationAdmission";
import { sandboxRunsAllowed } from "../../../services/runs/sandbox";

export const maxDuration = 960;

type SandboxImage = { readonly id: string; readonly version: string | null; readonly size: VmImageSelection["size"] };

type ParsedSandbox = {
  readonly task: string;
  readonly agent: CloudVmAgent;
  readonly timeoutMs: number;
  /** The image as the request named it (the idempotency digest uses this, not the resolution). */
  readonly requestedImage: string | null;
  /** Resolved after the replay lookup: a retry reuses the image its Run pinned. */
  readonly image?: SandboxImage;
};

type ParsedRunBody = {
  readonly source: { readonly repository?: string; readonly ref?: string; readonly commit?: string };
  readonly recipe: string;
  readonly desiredAttempts: number;
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
  readonly environment: "persistent" | "sandboxed";
  readonly sandbox?: ParsedSandbox;
};

type ParsedProviderRouting = {
  readonly provider: "cloud-vm";
  readonly routing: RunRoutingRequest;
};

function parseProviderRouting(body: Record<string, unknown>): ParsedProviderRouting | Response {
  if (body.provider !== undefined && body.provider !== "cloud-vm") return runError(new RunRequestError("run_provider_invalid", "The MVP provider is cloud-vm.", "Set provider to cloud-vm and retry."));
  const routingBody = jsonBodyObject(body.routing);
  const requestedProvider = routingBody?.requestedProvider;
  if (requestedProvider !== undefined && requestedProvider !== "freestyle" && requestedProvider !== "huge-blue" && requestedProvider !== "unknown") {
    return runError(new RunRequestError("run_provider_invalid", "routing.requestedProvider must be freestyle, huge-blue, or unknown.", "Set routing.requestedProvider to freestyle, huge-blue, or unknown and retry."));
  }
  return {
    provider: "cloud-vm",
    routing: { ...(requestedProvider !== undefined ? { requestedProvider } : {}) },
  };
}

/**
 * A sandboxed Run (hq#3367): one task on one VM from a manifest image, pinned here so the Run
 * records exactly what it booted. An image outside the manifest is refused, never booted.
 */
/** The image a sandbox pins: omitted means the base image; anything given must name a manifest image. */
function sandboxImage(image: string | undefined, userId: string): SandboxImage | Response {
  const invalid = (message: string) => runError(new RunRequestError("run_image_invalid", message, "Omit image for the default image, or name a manifest image id, and retry."));
  let selected: VmImageSelection;
  try {
    selected = resolveVmImage(defaultProviderId(), image, process.env, { kind: image === undefined ? "base" : undefined, callerUserId: userId });
  } catch (error) {
    if (!isVmImageConfigError(error)) throw error;
    return invalid("image is not a Cloud VM manifest image.");
  }
  if (!selected.manifestEntry) return invalid("A sandboxed run boots only a manifest image.");
  return { id: selected.image, version: selected.imageVersion, size: selected.size };
}

/**
 * The image this request's Run boots: the one a Run created under the same key already pinned
 * (a retry replays even after the manifest default moved), else a fresh resolution.
 */
async function pinSandboxImage(parsed: ParsedRunBody, userId: string, idempotencyKey: string): Promise<ParsedRunBody | Response> {
  if (!parsed.sandbox) return parsed;
  const existing = await findRunByIdempotencyKey(userId, idempotencyKey);
  // Sandboxes are a preview: off unless this deployment names the account (hq#3367). A retry of a
  // Run this account already created under the key replays even if the allowlist changed since.
  if (existing?.environment !== "sandboxed" && !sandboxRunsAllowed(userId)) {
    return runError(new RunRequestError("run_sandbox_unavailable", "Sandboxed runs are not enabled for this account.", "Use a persistent Run instead; sandboxed Runs are a preview enabled per account.", 403));
  }
  const image = existing?.environment === "sandboxed" && existing.imageId
    ? { id: existing.imageId, version: existing.imageVersion, size: findVmImageManifestEntry(defaultProviderId(), existing.imageId)?.size ?? null }
    : sandboxImage(parsed.sandbox.requestedImage ?? undefined, userId);
  if (image instanceof Response) return image;
  return { ...parsed, sandbox: { ...parsed.sandbox, image } };
}

/**
 * The most UTF-16 units a task may hold, whatever it counts as: four per character, so a task of
 * emoji at the app's character limit fits, and no cluster of combining marks makes one unbounded.
 */
const SANDBOX_TASK_MAX_UTF16 = 4 * SANDBOX_TASK_MAX_CHARS;

/**
 * A task's length as the app counts it (Swift's `String.count`: grapheme clusters), so every task
 * the composer lets through fits here too, within `SANDBOX_TASK_MAX_UTF16`. Stops counting once
 * past the limit.
 */
function taskCharacters(task: string): number {
  if (task.length <= SANDBOX_TASK_MAX_CHARS) return task.length;
  if (task.length > SANDBOX_TASK_MAX_UTF16) return SANDBOX_TASK_MAX_CHARS + 1;
  const segments = new Intl.Segmenter("en", { granularity: "grapheme" }).segment(task)[Symbol.iterator]();
  let count = 0;
  while (count <= SANDBOX_TASK_MAX_CHARS && !segments.next().done) count += 1;
  return count;
}

function parseSandboxBody(body: Record<string, unknown>): ParsedRunBody | Response {
  const task = typeof body.task === "string" ? body.task.trim() : "";
  if (!task || taskCharacters(task) > SANDBOX_TASK_MAX_CHARS) return runError(new RunRequestError("run_task_required", `task is required for a sandboxed run, at most ${SANDBOX_TASK_MAX_CHARS} characters.`, "Send a non-empty task within the limit and retry."));
  const agent = body.agent === undefined ? "codex" : body.agent;
  if (!CLOUD_VM_AGENTS.includes(agent as CloudVmAgent)) return runError(new RunRequestError("run_agent_invalid", `agent must be one of ${CLOUD_VM_AGENTS.join(", ")}.`, `Set agent to one of ${CLOUD_VM_AGENTS.join(", ")} and retry.`));
  const timeoutMs = body.timeoutMs === undefined ? SANDBOX_DEFAULT_TIMEOUT_MS : body.timeoutMs;
  if (typeof timeoutMs !== "number" || !Number.isSafeInteger(timeoutMs) || timeoutMs < SANDBOX_MIN_TIMEOUT_MS || timeoutMs > SANDBOX_MAX_TIMEOUT_MS) {
    return runError(new RunRequestError("run_timeout_invalid", `timeoutMs must be between ${SANDBOX_MIN_TIMEOUT_MS} and ${SANDBOX_MAX_TIMEOUT_MS}.`, "Set timeoutMs within that range and retry."));
  }
  if (body.desiredAttempts !== undefined && body.desiredAttempts !== 1) return runError(new RunRequestError("run_attempts_invalid", "A sandboxed run has exactly one attempt.", "Omit desiredAttempts or set it to 1 and retry."));
  // Omitted means the base image; anything given must name one (no empty, no null).
  if (body.image !== undefined && (typeof body.image !== "string" || !body.image.trim())) return runError(new RunRequestError("run_image_invalid", "image must be a manifest image id.", "Omit image for the default image, or name a manifest image id, and retry."));
  const providerRouting = parseProviderRouting(body);
  if (providerRouting instanceof Response) return providerRouting;
  return {
    source: {},
    recipe: SANDBOX_RUN_RECIPE,
    desiredAttempts: 1,
    provider: providerRouting.provider,
    routing: providerRouting.routing,
    environment: "sandboxed",
    sandbox: { task, agent: agent as CloudVmAgent, timeoutMs, requestedImage: typeof body.image === "string" ? body.image.trim() : null },
  };
}

function parseRunBody(body: Record<string, unknown>): ParsedRunBody | Response {
  if (body.environment !== undefined && body.environment !== "persistent" && body.environment !== "sandboxed") {
    return runError(new RunRequestError("run_environment_invalid", "environment must be persistent or sandboxed.", "Set environment to persistent or sandboxed and retry."));
  }
  return body.environment === "sandboxed" ? parseSandboxBody(body) : parseCreateRunBody(body);
}

/**
 * The idempotency digest. A persistent request hashes exactly the shape it had before sandboxes
 * existed, so a retry of a Run created before this deploy still replays instead of conflicting.
 */
function runRequestDigest(parsed: ParsedRunBody): string {
  const sandbox = parsed.sandbox;
  if (sandbox) {
    return requestDigest({
      environment: "sandboxed", task: sandbox.task, agent: sandbox.agent, timeoutMs: sandbox.timeoutMs,
      image: sandbox.requestedImage, routing: parsed.routing,
    });
  }
  return requestDigest({ source: parsed.source, recipe: parsed.recipe, desiredAttempts: parsed.desiredAttempts, provider: parsed.provider, routing: parsed.routing });
}

/**
 * A retry of a sandboxed Run answers that Run before any check that can change between the two
 * requests (provisioning scope, the allocation rate limit, the allowlist): a lost create response
 * must always be recoverable under its key. It launches nothing: the original request's
 * after-response launcher does, and if that process died, the abandoned-sandbox sweep fails a
 * Run left queued. A different request under the key goes the normal path (and conflicts).
 */
async function replaySandboxRun(parsed: ParsedRunBody, userId: string, idempotencyKey: string): Promise<Response | null> {
  if (!parsed.sandbox) return null;
  const existing = await findRunByIdempotencyKey(userId, idempotencyKey);
  if (existing?.environment !== "sandboxed" || existing.requestDigest !== runRequestDigest(parsed)) return null;
  const snapshot = await getRun(existing.id, userId);
  return runJson({
    id: snapshot.run.id,
    status: snapshot.run.status,
    attempts: snapshot.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status })),
    createdAt: snapshot.run.createdAt,
    environment: snapshot.run.environment,
    image: snapshot.run.imageId ? { id: snapshot.run.imageId, version: snapshot.run.imageVersion } : null,
    executionProvider: "cloud-vm",
    backendProvider: "freestyle",
    routing: runRoutingFor({ routing: parsed.routing, backendProvider: "freestyle" }),
    admission: runAdmissionFor({ backendProvider: "freestyle", accountEligible: true, limits: null }),
  }, 202);
}

/** The Run columns a sandbox adds; a persistent Run records no image. */
function environmentColumns(parsed: ParsedRunBody) {
  const image = parsed.sandbox?.image;
  return { environment: parsed.environment, imageId: image?.id ?? null, imageVersion: image?.version ?? null };
}

function parseCreateRunBody(body: Record<string, unknown>): ParsedRunBody | Response {
  const source = jsonBodyObject(body.source);
  const repository = typeof source?.repository === "string" ? source.repository.trim() : "";
  const commit = typeof source?.commit === "string" ? source.commit.trim() : "";
  const recipe = typeof body.recipe === "string" ? body.recipe.trim() : "";
  const desiredAttempts = typeof body.desiredAttempts === "number" && Number.isSafeInteger(body.desiredAttempts)
    ? body.desiredAttempts : 1;
  if (!/^[0-9a-f]{40}$/i.test(commit)) return runError(new RunRequestError("run_source_required", "source.commit must be a 40-character immutable commit SHA.", "Provide a 40-character commit SHA and retry."));
  if (!repository || repository.length > 512) return runError(new RunRequestError("run_source_required", "source.repository is required.", "Provide source.repository and retry."));
  if (!ALLOWED_RUN_RECIPES.includes(recipe as (typeof ALLOWED_RUN_RECIPES)[number])) return runError(new RunRequestError("run_recipe_required", "recipe must be an allowlisted internal recipe.", "Choose an allowlisted recipe and retry."));
  if (desiredAttempts < 1 || desiredAttempts > 32) return runError(new RunRequestError("run_attempts_invalid", "desiredAttempts must be between 1 and 32.", "Set desiredAttempts between 1 and 32 and retry."));
  const providerRouting = parseProviderRouting(body);
  if (providerRouting instanceof Response) return providerRouting;
  return {
    source: { repository, ref: typeof source?.ref === "string" ? source.ref.trim() : undefined, commit },
    recipe,
    desiredAttempts,
    provider: providerRouting.provider,
    routing: providerRouting.routing,
    environment: "persistent",
  };
}

type LaunchInput = {
  readonly user: Parameters<typeof launchSandboxRun>[0]["user"];
  readonly entitlements: Parameters<typeof launchSandboxRun>[0]["entitlements"];
  readonly parsed: ParsedRunBody;
  readonly requestedAt: number;
  readonly run: { readonly run: { readonly id: string; readonly source: RunSource; readonly recipe: string; readonly billingTeamId: string | null; readonly imageId: string | null; readonly imageVersion: string | null }; readonly attempts: readonly { readonly id: string; readonly ordinal: number; readonly status: string }[] };
};

/** Start the Run's queued attempts after the response; an idempotent replay starts nothing new. */
async function launchRun({ user, entitlements, parsed, requestedAt, run }: LaunchInput): Promise<void> {
  const attempts = run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status }));
  if (!parsed.sandbox) {
    await launchQueuedCloudVmAttempts({ user, entitlements, runId: run.run.id, attempts, source: run.run.source, recipe: run.run.recipe });
    return;
  }
  const attempt = attempts[0];
  if (attempt?.status !== "queued") return;
  // A replay under another team's scope launches nothing: the VM would land outside the Run's
  // billing scope, out of its reaper's reach. The sweep fails a Run nobody launched.
  if (run.run.billingTeamId !== entitlements.billingTeamId) return;
  // The image is the Run's own: a concurrent request with the same key may have resolved another.
  if (!run.run.imageId) return;
  const image = { id: run.run.imageId, version: run.run.imageVersion, size: findVmImageManifestEntry(defaultProviderId(), run.run.imageId)?.size ?? null };
  const { task, agent, timeoutMs } = parsed.sandbox;
  await launchSandboxRun({ user, entitlements, runId: run.run.id, attemptId: attempt.id, requestedAt, task, agent, timeoutMs, image });
}

export async function POST(request: Request): Promise<Response> {
  // maxDuration counts from here, so the sandbox launcher's deadline does too.
  const requestedAt = Date.now();
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
      if (!body) return runError(new RunRequestError("run_invalid_request", "Run body must be a JSON object.", "Send a JSON object and retry."));
      const parsedBody = parseRunBody(body);
      if (parsedBody instanceof Response) return parsedBody;
      const idempotencyKey = request.headers.get("idempotency-key")?.trim() || request.headers.get("x-cmux-idempotency-key")?.trim() || "";
      if (!idempotencyKey || idempotencyKey.length > 128) return runError(new RunRequestError("run_idempotency_required", "Idempotency-Key is required for Run creation.", "Add an Idempotency-Key header and retry."));
      const replay = await replaySandboxRun(parsedBody, user.id, idempotencyKey);
      if (replay) return replay;
      const scope = await resolveVmProvisioningAccountScope(user, request);
      if (!scope.ok) return scope.response;
      const pinned = await pinSandboxImage(parsedBody, user.id, idempotencyKey);
      if (pinned instanceof Response) return pinned;
      const parsed = pinned;
      if (parsed.routing.requestedProvider === "huge-blue") {
        return runError(new RunRequestError("run_provider_unavailable", "The Huge Blue Run adapter is not configured for this deployment.", "Choose the freestyle provider and retry.", 409, { reasonCode: "adapter_not_configured" }));
      }
      if (parsed.routing.requestedProvider === "unknown") {
        return runError(new RunRequestError("run_provider_invalid", "The requested Run provider is not recognized.", "Choose a supported Run provider and retry.", 400, { reasonCode: "provider_unknown" }));
      }
      try {
        const admitted = await createRunWithAllocationAdmission({
          request,
          billingTeamId: scope.entitlements.billingTeamId,
          run: {
            userId: user.id,
            billingTeamId: scope.entitlements.billingTeamId,
            idempotencyKey,
            requestDigest: runRequestDigest(parsed),
            source: parsed.source,
            recipe: parsed.recipe,
            provider: parsed.provider,
            desiredAttempts: parsed.desiredAttempts,
            ...environmentColumns(parsed),
          },
        });
        if (admitted.kind === "limited") return admitted.response;
        const run = admitted.run;
        runAfterResponse(() => launchRun({ user, entitlements: scope.entitlements, parsed, requestedAt, run }));
        const accountClass = scope.entitlements.billingCustomerType === "team" ? "team" : "personal";
        return runJson({
          id: run.run.id,
          status: run.run.status,
          attempts: run.attempts.map((attempt) => ({ id: attempt.id, ordinal: attempt.ordinal, status: attempt.status })),
          createdAt: run.run.createdAt,
          environment: run.run.environment,
          image: run.run.imageId ? { id: run.run.imageId, version: run.run.imageVersion } : null,
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

