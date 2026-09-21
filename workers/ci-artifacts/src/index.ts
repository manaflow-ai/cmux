import { DurableObject } from "cloudflare:workers";
import { authenticateActionsRequest, type ActionsIdentity } from "./actions-oidc";

const REPOSITORY = "manaflow-ai/cmux";
const MAX_BYTES = 2 * 1024 ** 3;
const IMPORT_TIMEOUT_MS = 150_000;
const API_LIMIT = 2 * 1024 ** 2;
const CALLER_AUTH_TIMEOUT_MS = 5_000;
const ADMISSION_TIMEOUT_MS = 2_000;
const REQUESTS_PER_RUN_PER_MINUTE = 16;
const REQUESTS_GLOBAL_PER_MINUTE = 120;

class ArtifactError extends Error {}

type Artifact = { id: number; digest: string; size: number; run: number };
type Cached = Artifact & { key: string; cache: "hit" | "fill" };

function route(request: Request): { id: number; digest: string } | null {
  const url = new URL(request.url);
  const match = /^\/v1\/manaflow-ai\/cmux\/artifacts\/([1-9][0-9]{0,18})\/([a-f0-9]{64})\.zip$/.exec(url.pathname);
  if (request.method !== "GET" || url.search || !match) return null;
  const id = Number(match[1]);
  return Number.isSafeInteger(id) ? { id, digest: match[2] } : null;
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ArtifactError("invalid metadata");
  return value as Record<string, unknown>;
}

async function bounded<T>(work: Promise<T>, milliseconds: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new ArtifactError("cache deadline exceeded")), milliseconds);
  });
  try { return await Promise.race([work, deadline]); }
  finally { if (timer !== undefined) clearTimeout(timer); }
}

async function api(path: string, token: string, signal: AbortSignal): Promise<Record<string, unknown>> {
  const response = await fetch(`https://api.github.com/repos/${REPOSITORY}${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "User-Agent": "cmux-ci-artifacts" },
    redirect: "manual", signal,
  });
  if (!response.ok || !response.body) throw new ArtifactError("metadata unavailable");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      length += chunk.value.byteLength;
      if (length > API_LIMIT) throw new ArtifactError("metadata too large");
      chunks.push(chunk.value);
    }
  } finally {
    await reader.cancel();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return object(JSON.parse(new TextDecoder().decode(bytes)));
}

async function authorize(
  id: number, digest: string, token: string, signal: AbortSignal,
  expectedRunId?: number, expectedRunAttempt?: number,
): Promise<Artifact> {
  // Revalidate even a cache hit: an expired artifact or newly private repo is
  // not a public download. The bucket must not have a public domain/r2.dev URL.
  const repository = await api("", token, signal);
  if (repository.private !== false || repository.full_name !== REPOSITORY) throw new ArtifactError("repository not public");
  const artifact = await api(`/actions/artifacts/${id}`, token, signal);
  const name = typeof artifact.name === "string" ? /^app-host-products-v1-[a-f0-9]{64}-([1-9][0-9]*)$/.exec(artifact.name) : null;
  const size = artifact.size_in_bytes;
  if (artifact.id !== id || artifact.expired !== false || artifact.digest !== `sha256:${digest}` || !name
      || typeof size !== "number" || !Number.isSafeInteger(size) || size <= 0 || size > MAX_BYTES) {
    throw new ArtifactError("invalid artifact identity");
  }
  const runId = object(artifact.workflow_run).id;
  if (typeof runId !== "number" || !Number.isSafeInteger(runId) || runId <= 0) throw new ArtifactError("invalid producer");
  const run = await api(`/actions/runs/${runId}`, token, signal);
  const attempt = Number(name[1]);
  if ((expectedRunId !== undefined && runId !== expectedRunId)
      || (expectedRunAttempt !== undefined && attempt !== expectedRunAttempt)
      || run.path !== ".github/workflows/ci.yml"
      || !["pull_request", "merge_group", "workflow_dispatch"].includes(String(run.event))
      || object(run.head_repository).full_name !== REPOSITORY || run.run_attempt !== attempt) {
    throw new ArtifactError("invalid producer");
  }
  // The full CI run is deliberately allowed to remain in progress: its test
  // consumers are waiting for this artifact. Only the producer must finish.
  for (let page = 1; page <= 3; page++) {
    const response = await api(`/actions/runs/${runId}/attempts/${attempt}/jobs?per_page=100&page=${page}`, token, signal);
    if (!Array.isArray(response.jobs)) throw new ArtifactError("invalid producer jobs");
    if (response.jobs.some((raw: unknown) => {
      const job = object(raw);
      return job.name === "macOS compile admission" && job.status === "completed" && job.conclusion === "success";
    })) return { id, digest, size, run: runId };
    if (response.jobs.length < 100) break;
  }
  throw new ArtifactError("producer not successful");
}

async function archive(artifact: Artifact, token: string, signal: AbortSignal): Promise<Response> {
  const redirect = await fetch(`https://api.github.com/repos/${REPOSITORY}/actions/artifacts/${artifact.id}/zip`, {
    headers: { Authorization: `Bearer ${token}`, "User-Agent": "cmux-ci-artifacts" }, redirect: "manual", signal,
  });
  await redirect.body?.cancel();
  const location = redirect.headers.get("Location");
  if (redirect.status !== 302 || !location) throw new ArtifactError("artifact unavailable");
  const url = new URL(location);
  if (url.protocol !== "https:" || url.username || url.password
      || !(url.hostname.endsWith(".blob.core.windows.net") || url.hostname.endsWith(".githubusercontent.com"))) {
    throw new ArtifactError("unexpected artifact host");
  }
  // Never forward the server token to the signed blob URL (or another redirect).
  const response = await fetch(url, { redirect: "manual", signal });
  if (!response.ok || !response.body || Number(response.headers.get("Content-Length")) !== artifact.size) {
    await response.body?.cancel();
    throw new ArtifactError("artifact size unavailable");
  }
  return response;
}

type AdmissionState = { minute: number; total: number; runs: Record<string, number> };

export class RequestAdmission extends DurableObject<Env> {
  private serial: Promise<void> = Promise.resolve();

  private async admit(runId: string): Promise<boolean> {
    let allowed = false;
    const operation = this.serial.then(async () => {
      const minute = Math.floor(Date.now() / 60_000);
      const stored = await this.ctx.storage.get<AdmissionState>("rate");
      const state: AdmissionState = stored?.minute === minute
        ? stored : { minute, total: 0, runs: {} };
      const runCount = state.runs[runId] || 0;
      if (state.total >= REQUESTS_GLOBAL_PER_MINUTE || runCount >= REQUESTS_PER_RUN_PER_MINUTE) return;
      state.total++;
      state.runs[runId] = runCount + 1;
      await this.ctx.storage.put("rate", state);
      allowed = true;
    });
    this.serial = operation.catch(() => {});
    await operation;
    return allowed;
  }

  async fetch(request: Request): Promise<Response> {
    const runId = request.headers.get("X-Cmux-Run-Id") || "";
    if (!/^[1-9][0-9]{0,19}$/.test(runId)) return new Response("invalid admission identity", { status: 400 });
    return new Response(null, { status: await this.admit(runId) ? 204 : 429 });
  }
}

export class ArtifactImport extends DurableObject<Env> {
  private importing: Promise<Cached> | undefined;

  private async ensure(
    id: number, digest: string, timeout: number,
    expectedRunId?: number, expectedRunAttempt?: number,
  ): Promise<Cached> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    const signal = controller.signal;
    try {
      const artifact = await bounded(authorize(
        id, digest, this.env.GITHUB_ARTIFACT_TOKEN, signal, expectedRunId, expectedRunAttempt,
      ), timeout);
      const key = `github/${REPOSITORY}/${id}/${digest}.zip`;
      const existing = await bounded(this.env.ARTIFACTS.head(key), 10_000);
      if (existing?.size === artifact.size && existing.customMetadata?.sha256 === digest) {
        return { ...artifact, key, cache: "hit" };
      }
      const response = await archive(artifact, this.env.GITHUB_ARTIFACT_TOKEN, signal);
      // FixedLengthStream rejects short/oversized bodies. R2 verifies SHA-256 as
      // it receives the stream and does not commit an object with a bad checksum.
      const stream = new FixedLengthStream(artifact.size);
      const copying = response.body!.pipeTo(stream.writable, { signal });
      const storing = this.env.ARTIFACTS.put(key, stream.readable, {
        sha256: digest,
        httpMetadata: { contentType: "application/zip", cacheControl: "no-store" },
        customMetadata: { sha256: digest, artifact_id: String(id), run_id: String(artifact.run) },
      });
      try {
        await Promise.all([copying, storing]);
      } catch (error) {
        controller.abort();
        // Keep singleflight ownership until both transfer legs settle. In
        // particular an R2 failure must not leave a GitHub download running.
        await Promise.allSettled([copying, storing]);
        throw error;
      }
      return { ...artifact, key, cache: "fill" };
    } finally {
      controller.abort();
      clearTimeout(timer);
    }
  }

  async fetch(request: Request): Promise<Response> {
    const identity = route(request);
    if (!identity) return new Response("Not found", { status: 404 });
    try {
      const expectedRunHeader = request.headers.get("X-Cmux-Expected-Run-Id");
      const expectedAttemptHeader = request.headers.get("X-Cmux-Expected-Run-Attempt");
      const expectedRunId = expectedRunHeader === null ? undefined : Number(expectedRunHeader);
      const expectedRunAttempt = expectedAttemptHeader === null ? undefined : Number(expectedAttemptHeader);
      if ((expectedRunHeader !== null && (!Number.isSafeInteger(expectedRunId) || expectedRunId! <= 0))
          || (expectedAttemptHeader !== null && (!Number.isSafeInteger(expectedRunAttempt) || expectedRunAttempt! <= 0))) {
        throw new ArtifactError("invalid caller run");
      }
      // State belongs to this artifact's Durable Object, not a Worker isolate.
      // Concurrent consumers await one import, rather than downloading six ZIPs.
      const configured = Number(this.env.IMPORT_TIMEOUT_MS);
      const timeout = Number.isFinite(configured) && configured >= 25
        ? Math.min(configured, IMPORT_TIMEOUT_MS) : IMPORT_TIMEOUT_MS;
      this.importing ??= this.ensure(
        identity.id, identity.digest, timeout, expectedRunId, expectedRunAttempt,
      ).finally(() => {
        this.importing = undefined;
      });
      // HTTP callers have a deadline even if an R2 binding call stalls. The
      // import promise retains ownership until transfer cleanup actually ends.
      const cached = await bounded(this.importing, timeout);
      const result = await bounded(this.env.ARTIFACTS.get(cached.key), 10_000);
      if (!result || result.size !== cached.size) throw new ArtifactError("cached artifact unavailable");
      console.log(JSON.stringify({ event: "artifact", id: cached.id, cache: cached.cache, bytes: cached.size }));
      return new Response(result.body, { headers: {
        "Content-Type": "application/zip", "Content-Length": String(result.size),
        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
        "X-Cmux-Artifact-Cache": cached.cache,
      } });
    } catch (error) {
      // Do not log signed download URLs, tokens, or response bodies.
      console.warn(JSON.stringify({ event: "artifact-miss", id: identity.id, reason: error instanceof ArtifactError ? error.message : error instanceof Error ? error.name : "unknown" }));
      return new Response("Artifact cache unavailable; use GitHub", { status: 502, headers: { "Cache-Control": "no-store" } });
    }
  }
}

export async function artifactHandler(
  request: Request, env: Env, expectedRunId?: string, expectedRunAttempt?: string,
): Promise<Response> {
  const identity = route(request);
  if (!identity) return new Response("Not found", { status: 404 });
  // Strip caller credentials before the request enters the artifact Durable Object.
  const headers = new Headers();
  if (expectedRunId !== undefined) headers.set("X-Cmux-Expected-Run-Id", expectedRunId);
  if (expectedRunAttempt !== undefined) headers.set("X-Cmux-Expected-Run-Attempt", expectedRunAttempt);
  const internal = new Request(request.url, { method: "GET", headers });
  const owner = expectedRunId === undefined ? "unbound" : `run/${expectedRunId}/${expectedRunAttempt}`;
  return env.ARTIFACT_IMPORTS.getByName(`${REPOSITORY}/${owner}/${identity.id}/${identity.digest}`).fetch(internal);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!route(request)) return new Response("Not found", { status: 404 });
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CALLER_AUTH_TIMEOUT_MS);
    let caller: ActionsIdentity;
    try {
      caller = await bounded(
        authenticateActionsRequest(request, fetch, Date.now(), controller.signal),
        CALLER_AUTH_TIMEOUT_MS,
      );
      const admission = await bounded(
        env.REQUEST_ADMISSION.getByName("production").fetch(new Request("https://admission.internal/admit", {
          headers: { "X-Cmux-Run-Id": caller.runId },
        })),
        ADMISSION_TIMEOUT_MS,
      );
      if (admission.status === 429) {
        console.warn(JSON.stringify({ event: "artifact-rate-limited", run: caller.runId }));
        return new Response("Artifact broker busy; use GitHub", { status: 429, headers: { "Cache-Control": "no-store" } });
      }
      if (admission.status !== 204) throw new ArtifactError("request admission unavailable");
    } catch (error) {
      console.warn(JSON.stringify({ event: "artifact-auth-miss", reason: error instanceof Error ? error.message : "unknown" }));
      return new Response("Artifact broker authentication unavailable; use GitHub", {
        status: 502, headers: { "Cache-Control": "no-store" },
      });
    } finally {
      controller.abort();
      clearTimeout(timer);
    }
    return artifactHandler(request, env, caller.runId, caller.runAttempt);
  },
} satisfies ExportedHandler<Env>;
