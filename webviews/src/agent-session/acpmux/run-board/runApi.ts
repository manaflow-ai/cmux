import type { AcpmuxRow } from "../model";
import type { RunArtifact, RunAttempt, RunBoardSnapshot } from "./model";
export type { AttachTicket } from "./model";

/** The JSON shape returned by the Run control plane. */
export type RunApiRun = {
  id: string;
  specDigest?: string | null;
  userId?: string;
  source: { repository?: string; ref?: string; commit?: string; archiveDigest?: string; setupManifestDigest?: string; imageDigest?: string };
  recipe: string;
  provider?: string;
  desiredAttempts: number;
  status: string;
  createdAt?: string;
  updatedAt?: string;
  error?: string | null;
};

export type RunApiAttempt = {
  id: string;
  runId?: string;
  ordinal: number;
  variant?: { id: string; label: string; instruction?: string; instructionDigest?: string };
  status: string;
  providerVmId?: string | null;
  runtimeId?: string | null;
  placement?: { executionProvider?: string; backendProvider?: string; sessionId?: string | null };
  attachable?: boolean;
  retainedUntil?: string | null;
  result?: Record<string, unknown> | null;
  exitCode?: number | null;
  error?: string | null;
  startedAt?: string | null;
  finishedAt?: string | null;
};

export type RunApiArtifact = {
  id: string;
  runId?: string;
  attemptId: string;
  name: string;
  mediaType?: string;
  sizeBytes: number;
  digest: string;
  uri: string;
  metadata?: Record<string, unknown> | null;
  createdAt?: string;
};

export type RunApiSnapshot = {
  run: RunApiRun;
  attempts: RunApiAttempt[];
  artifacts: RunApiArtifact[];
  events?: RunApiEvent[];
  /** A future API may include the event cursor captured by the snapshot. */
  cursor?: string;
};

/** Flat receipt returned by the Cloud `/api/runs` routes. */
export type RunApiReceipt = {
  id: string;
  status: string;
  provider?: string;
  requestDigest?: string | null;
  desiredAttempts: number;
  source?: RunApiRun["source"];
  recipe?: string;
  createdAt?: string;
  updatedAt?: string;
  completedAt?: string | null;
  error?: string | null;
  attempts: RunApiAttempt[];
  events?: RunApiEvent[];
  artifacts?: RunApiArtifact[];
};

export type RunApiEvent = {
  id: string;
  runId: string;
  attemptId?: string | null;
  sequence: number;
  attemptSequence?: number | null;
  externalId?: string | null;
  kind: string;
  payload: Record<string, unknown>;
  createdAt?: string;
};

export type RunApiEventPage = { events: RunApiEvent[]; nextCursor?: string | null };

export type RunCreateInput = {
  source: { repository: string; commit: string; ref?: string; setupManifestDigest: string };
  /** Human-readable shared intent; the wire contract stores only its digest. */
  intent?: string;
  recipe: "parallel-review";
  desiredAttempts: number;
  provider?: "cloud-vm";
  routing?: { requestedProvider?: "freestyle" | "huge-blue" | "unknown" };
  variants: Array<{ id: string; label: string; instruction: string }>;
};

export type RunCreateResponse = RunApiReceipt & {
  id: string;
  specDigest?: string | null;
  status: string;
  executionProvider?: string;
  backendProvider?: string;
};

export type RunAttachTicketMint = {
  ticket: string;
  runId: string;
  attemptId: string;
  provider: string;
  providerVmId: string;
  providerWorkspaceId: string;
  providerTerminalId: string;
  expiresAt: string;
};

export type RunAttachTarget = RunAttachTicketMint & {
  endpoint?: {
    transport?: string;
    route?: string;
    token?: string;
    session?: string;
    expiresAtUnix?: number;
  };
  transport?: string;
  route?: string;
  token?: string;
  session?: string;
  expiresAtUnix?: number;
};

export type RunPromotionResponse = {
  id: string;
  runId: string;
  attemptId: string;
  runtime?: { id: string; state?: string; sessionId?: string | null };
  workspace?: { id: string; kind?: string; state?: string; sessionId?: string | null };
  attach?: { transport?: string; capability?: string; sessionId?: string | null; reconnectable?: boolean; expiresAt?: string | null };
  createdAt?: string;
};

export type AttachTicketIntent = {
  runId: string;
  attemptId: string;
  sessionId: string;
  cursor: string;
};

export type RunApiClient = {
  getSnapshot(runId: string): Promise<RunApiSnapshot | RunApiReceipt | RunBoardSnapshot>;
  getEvents(runId: string, after?: string): Promise<RunApiEventPage>;
  createRun(input: RunCreateInput, idempotencyKey: string): Promise<RunCreateResponse>;
  mintAttachTicket(runId: string, attemptId: string, ttlMs?: number): Promise<RunAttachTicketMint>;
  redeemAttachTicket(runId: string, attemptId: string, ticket: string): Promise<RunAttachTarget>;
  promoteAttempt(runId: string, attemptId: string, idempotencyKey: string): Promise<RunPromotionResponse>;
};

export type RunApiClientOptions = {
  baseUrl?: string;
  fetch?: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;
  headers?: HeadersInit;
};

export class RunApiHttpError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(status: number, message: string, code?: string) {
    super(message);
    this.name = "RunApiHttpError";
    this.status = status;
    this.code = code;
  }
}

function apiOrigin(baseUrl?: string): string {
  if (baseUrl) return baseUrl.replace(/\/$/, "");
  if (typeof window !== "undefined" && window.location.origin) return window.location.origin;
  return "";
}

function apiUrl(baseUrl: string, path: string): string {
  return baseUrl ? `${baseUrl}${path}` : path;
}

async function readJson(response: Response): Promise<unknown> {
  return response.json().catch(() => ({}));
}

const RUN_SPEC_SCHEMA = "cmux.run/v1" as const;

async function sha256Digest(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return `sha256:${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function toRunSpec(input: RunCreateInput, operationId: string): Promise<Record<string, unknown>> {
  const intent = input.intent?.trim() || input.variants.map((variant) => `${variant.id}:${variant.instruction}`).join("\n");
  return {
    schema: RUN_SPEC_SCHEMA,
    operationId,
    source: input.source,
    intent: { digest: await sha256Digest(intent) },
    recipe: { id: input.recipe, version: 1 },
    variants: await Promise.all(input.variants.map(async (variant) => ({
      id: variant.id,
      label: variant.label,
      instruction: variant.instruction,
      instructionDigest: await sha256Digest(variant.instruction),
    }))),
    workspace: { kind: "ephemeral" },
    resources: { maxAttempts: input.desiredAttempts, maxConcurrent: Math.min(2, input.desiredAttempts) },
    routing: { executionProvider: "cloud-vm", backend: input.routing?.requestedProvider ?? "auto" },
    capabilities: { secretRefs: [] },
    checks: [],
    policy: { mode: "thunderdome", humanApprovalRequired: true, evidenceKinds: ["screenshot", "recording", "patch"] },
  };
}

/** Same-origin HTTP transport used by the real Run board. */
export function createRunApiClient(options: RunApiClientOptions = {}): RunApiClient {
  const request = options.fetch ?? globalThis.fetch;
  const baseUrl = apiOrigin(options.baseUrl);
  const headers = new Headers(options.headers);
  headers.set("Accept", "application/json");
  const jsonRequest = async <T>(path: string, init: RequestInit, message: string): Promise<T> => {
    const response = await request(apiUrl(baseUrl, path), {
      credentials: "same-origin",
      ...init,
      headers: (() => {
        const merged = new Headers(headers);
        new Headers(init.headers).forEach((value, key) => merged.set(key, value));
        merged.set("Content-Type", "application/json");
        return merged;
      })(),
    });
    const body = await readJson(response);
    if (!response.ok) {
      const error = body as { error?: string; message?: string };
      throw new RunApiHttpError(response.status, error.message ?? `${message} (${response.status})`, error.error);
    }
    return body as T;
  };
  return {
    async getSnapshot(runId) {
      const response = await request(apiUrl(baseUrl, `/api/runs/${encodeURIComponent(runId)}`), {
        credentials: "same-origin",
        headers,
      });
      const body = await readJson(response);
      if (!response.ok) {
        const error = body as { error?: string; message?: string };
        throw new RunApiHttpError(response.status, error.message ?? `Run snapshot failed (${response.status})`, error.error);
      }
      return body as RunApiSnapshot;
    },
    async getEvents(runId, after) {
      const query = after ? `?after=${encodeURIComponent(after)}` : "";
      const response = await request(apiUrl(baseUrl, `/api/runs/${encodeURIComponent(runId)}/events${query}`), {
        credentials: "same-origin",
        headers,
      });
      const body = await readJson(response);
      if (response.ok) {
        const result = body as Partial<RunApiEventPage>;
        return { events: Array.isArray(result.events) ? result.events : [], nextCursor: result.nextCursor ?? null };
      }
      // The first Cloud rollout exposes events on the durable Run receipt while
      // the dedicated event route is being deployed. Keep replay live across
      // that cutover, but only fall back for a missing route; auth and server
      // errors must remain visible to the board.
      if (response.status !== 404) {
        const error = body as { error?: string; message?: string };
        throw new RunApiHttpError(response.status, error.message ?? `Run events failed (${response.status})`, error.error);
      }
      const snapshotResponse = await request(apiUrl(baseUrl, `/api/runs/${encodeURIComponent(runId)}`), {
        credentials: "same-origin",
        headers,
      });
      const snapshotBody = await readJson(snapshotResponse);
      if (!snapshotResponse.ok) {
        const error = snapshotBody as { error?: string; message?: string };
        throw new RunApiHttpError(snapshotResponse.status, error.message ?? `Run snapshot failed (${snapshotResponse.status})`, error.error);
      }
      const snapshot = snapshotBody as { events?: unknown };
      const afterSequence = decodeCursorSequence(after) ?? -1;
      const events = Array.isArray(snapshot.events)
        ? snapshot.events.filter((event): event is RunApiEvent => {
            if (!event || typeof event !== "object") return false;
            const candidate = event as Partial<RunApiEvent>;
            return typeof candidate.sequence === "number" && candidate.sequence > afterSequence;
          })
        : [];
      return { events, nextCursor: null };
    },
    async createRun(input, idempotencyKey) {
      if (input.routing?.requestedProvider === "huge-blue") {
        throw new RunApiHttpError(409, "Huge Blue is not enabled for Cloud Runs yet.", "provider_not_enabled");
      }
      const spec = await toRunSpec(input, idempotencyKey);
      return jsonRequest<RunCreateResponse>("/api/runs", {
        method: "POST",
        headers: { "idempotency-key": idempotencyKey },
        body: JSON.stringify(spec),
      }, "Run creation failed");
    },
    async mintAttachTicket(runId, attemptId, ttlMs) {
      return jsonRequest<RunAttachTicketMint>(`/api/runs/${encodeURIComponent(runId)}/attempts/${encodeURIComponent(attemptId)}/attach-ticket`, {
        method: "POST",
        body: JSON.stringify(ttlMs === undefined ? {} : { ttlMs }),
      }, "Attach ticket mint failed");
    },
    async redeemAttachTicket(runId, attemptId, ticket) {
      return jsonRequest<RunAttachTarget>(`/api/runs/${encodeURIComponent(runId)}/attempts/${encodeURIComponent(attemptId)}/attach-ticket`, {
        method: "POST",
        body: JSON.stringify({ ticket }),
      }, "Attach ticket redeem failed");
    },
    async promoteAttempt(runId, attemptId, idempotencyKey) {
      return jsonRequest<RunPromotionResponse>(`/api/runs/${encodeURIComponent(runId)}/attempts/${encodeURIComponent(attemptId)}/promote`, {
        method: "POST",
        headers: { "idempotency-key": idempotencyKey },
        body: JSON.stringify({}),
      }, "Attempt promotion failed");
    },
  };
}

function encodeCursor(sequence: number): string {
  return encodeBase64Url(JSON.stringify({ sequence }));
}

function decodeCursorSequence(value: string | undefined): number | undefined {
  if (!value) return undefined;
  if (/^\d+$/.test(value)) return Number(value);
  try {
    const encoded = value.replaceAll("-", "+").replaceAll("_", "/");
    const padded = encoded + "=".repeat((4 - (encoded.length % 4)) % 4);
    const json = typeof atob === "function" ? atob(padded) : Buffer.from(value, "base64url").toString("utf8");
    const parsed = JSON.parse(json) as { sequence?: unknown };
    return typeof parsed.sequence === "number" && Number.isSafeInteger(parsed.sequence) ? parsed.sequence : undefined;
  } catch {
    return undefined;
  }
}

function encodeBase64Url(value: string): string {
  if (typeof btoa === "function") return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  return Buffer.from(value, "utf8").toString("base64url");
}

function isSnapshot(value: RunApiSnapshot | RunApiReceipt | RunBoardSnapshot): value is RunApiSnapshot {
  return "run" in value && typeof value.run === "object";
}

function isReceipt(value: RunApiSnapshot | RunApiReceipt | RunBoardSnapshot): value is RunApiReceipt {
  return "id" in value && typeof value.id === "string" && "status" in value && typeof value.status === "string" && Array.isArray(value.attempts);
}

function receiptSnapshot(receipt: RunApiReceipt): RunApiSnapshot {
  return {
    run: {
      id: receipt.id,
      source: receipt.source ?? {},
      recipe: receipt.recipe ?? "parallel-review",
      provider: receipt.provider,
      desiredAttempts: receipt.desiredAttempts,
      status: receipt.status,
      createdAt: receipt.createdAt,
      updatedAt: receipt.updatedAt,
      error: receipt.error,
    },
    attempts: receipt.attempts,
    artifacts: receipt.artifacts ?? [],
    events: receipt.events ?? [],
  };
}

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) ? value : undefined;
}

function attemptState(status: string): RunAttempt["state"] {
  if (status === "succeeded") return "completed";
  if (status === "failed" || status === "cancelled" || status === "expired") return "failed";
  return "running";
}

function resultValue(result: Record<string, unknown>, key: string): unknown {
  return result[key];
}

function artifactKind(artifact: RunApiArtifact): RunArtifact["kind"] {
  const metadata = record(artifact.metadata);
  const declared = stringValue(metadata.kind);
  if (declared === "screenshot" || declared === "recording" || declared === "patch") return declared;
  const name = artifact.name.toLowerCase();
  if (/\.(png|jpe?g|gif|webp)$/.test(name)) return "screenshot";
  if (/\.(webm|mp4|mov|mkv)$/.test(name)) return "recording";
  return "patch";
}

function mapArtifact(artifact: RunApiArtifact): RunArtifact {
  return {
    id: artifact.id,
    name: artifact.name,
    kind: artifactKind(artifact),
    digest: artifact.digest,
    verified: /^sha256:[0-9a-f]{64}$/i.test(artifact.digest),
  };
}

function rowsFromResult(result: Record<string, unknown>): AcpmuxRow[] {
  const rows = result.rows;
  return Array.isArray(rows) ? (rows as AcpmuxRow[]) : [];
}

function mapAttempt(attempt: RunApiAttempt, artifacts: RunApiArtifact[]): RunAttempt {
  const result = record(attempt.result);
  const tests = record(resultValue(result, "tests"));
  const passed = numberValue(tests.passed) ?? numberValue(resultValue(result, "testsPassed")) ?? 0;
  const failed = numberValue(tests.failed) ?? numberValue(resultValue(result, "testsFailed")) ?? 0;
  const buildValue = stringValue(resultValue(result, "build"));
  const state = attemptState(attempt.status);
  const providerVmId = stringValue(attempt.providerVmId);
  const placement = record(attempt.placement);
  const sessionId = stringValue(placement.sessionId) ?? stringValue(resultValue(result, "sessionId")) ?? providerVmId ?? attempt.id;
  const backendProvider = stringValue(placement.backendProvider);
  const rawVariant = attempt.variant;
  const variant = rawVariant
    ? {
        id: rawVariant.id,
        label: rawVariant.label,
        instruction: rawVariant.instruction ?? (rawVariant.instructionDigest ? `Instruction digest ${rawVariant.instructionDigest.slice(0, 19)}…` : "Recipe instructions are sealed by digest."),
        ...(rawVariant.instructionDigest ? { instructionDigest: rawVariant.instructionDigest } : {}),
      }
    : { id: `attempt-${attempt.ordinal + 1}`, label: `Attempt ${String.fromCharCode(65 + attempt.ordinal)}`, instruction: "Explore the shared intent independently and publish build, test, and artifact evidence." };
  return {
    id: attempt.id,
    label: stringValue(resultValue(result, "label")) ?? `Attempt ${String.fromCharCode(65 + attempt.ordinal)}`,
    direction: stringValue(resultValue(result, "direction")) ?? variant.label,
    variant,
    worker: `${backendProvider ?? stringValue(resultValue(result, "provider")) ?? "cloud-vm"}${providerVmId ? ` · ${providerVmId}` : ""}`,
    sessionId,
    attachable: attempt.attachable,
    state,
    activity:
      stringValue(resultValue(result, "activity")) ??
      (state === "completed" ? "Finished. Ready for your review." : state === "failed" ? attempt.error ?? "Attempt failed." : "Working on the shared intent."),
    build: buildValue === "failed" || state === "failed" ? "failed" : buildValue === "passed" || state === "completed" ? "passed" : "pending",
    tests: { passed, failed },
    artifacts: artifacts.filter((item) => item.attemptId === attempt.id).map(mapArtifact),
    rows: rowsFromResult(result),
  };
}

export function normalizeRunSnapshot(value: RunApiSnapshot | RunApiReceipt | RunBoardSnapshot): RunBoardSnapshot {
  if (!isSnapshot(value) && !isReceipt(value)) return value;
  const snapshot = isReceipt(value) ? receiptSnapshot(value) : value;
  const source = snapshot.run.source ?? {};
  const commit = source.commit ? ` @ ${source.commit.slice(0, 12)}` : "";
  const cursor = decodeCursorSequence(snapshot.cursor) ?? snapshot.events?.at(-1)?.sequence;
  return {
    id: snapshot.run.id,
    title: `Run ${snapshot.run.id.slice(0, 8)}`,
    intent: `${snapshot.run.recipe} on ${source.repository ?? "the attached repository"}${commit}`,
    source: `${source.repository ?? "repository"}${commit}`,
    cursor: cursor === undefined ? "0" : String(cursor),
    attempts: snapshot.attempts.map((attempt) => mapAttempt(attempt, snapshot.artifacts)),
  };
}

function eventText(event: RunApiEvent): string | undefined {
  const payload = record(event.payload);
  return stringValue(payload.text) ?? stringValue(payload.output) ?? stringValue(payload.message) ?? stringValue(payload.error);
}

function appendEventRow(attempt: RunAttempt, event: RunApiEvent): RunAttempt {
  const text = eventText(event);
  if (!text) return attempt;
  const at = event.createdAt ? Date.parse(event.createdAt) : Date.now();
  const row: AcpmuxRow = event.kind === "attempt.output"
    ? { id: event.id, version: 1, at, kind: "activity", items: [{ kind: "tool", text: "Agent output", tool: { id: event.id, title: "Agent output", kind: "execute", status: "completed", output: text } }] }
    : { id: event.id, version: 1, at, kind: "assistant", text };
  return { ...attempt, rows: [...attempt.rows, row], activity: text.slice(0, 240) };
}

export function applyRunEvent(snapshot: RunBoardSnapshot, event: RunApiEvent): RunBoardSnapshot {
  const attemptId = event.attemptId ?? undefined;
  const index = attemptId ? snapshot.attempts.findIndex((attempt) => attempt.id === attemptId) : -1;
  if (index < 0) return { ...snapshot, cursor: String(Math.max(Number(snapshot.cursor) || 0, event.sequence)) };
  const current = snapshot.attempts[index]!;
  const payload = record(event.payload);
  let next = appendEventRow(current, event);
  if (event.kind === "attempt.started") {
    const providerVmId = stringValue(payload.providerVmId);
    next = { ...next, state: "running", worker: providerVmId ? `cloud-vm · ${providerVmId}` : next.worker, sessionId: providerVmId ?? next.sessionId, activity: "Agent started." };
  } else if (event.kind === "attempt.succeeded") {
    next = { ...next, state: "completed", build: "passed", activity: "Finished. Ready for your review." };
  } else if (event.kind === "attempt.failed") {
    next = { ...next, state: "failed", build: "failed", activity: eventText(event) ?? "Attempt failed." };
  } else if (event.kind === "attempt.artifact") {
    const digest = stringValue(payload.digest);
    const name = stringValue(payload.name);
    if (digest && name && !next.artifacts.some((artifact) => artifact.digest === digest || artifact.name === name)) {
      next = { ...next, artifacts: [...next.artifacts, { id: stringValue(payload.artifactId) ?? `${event.id}-artifact`, name, kind: artifactKind({ id: "", attemptId: current.id, name, sizeBytes: numberValue(payload.sizeBytes) ?? 0, digest, uri: "artifact://event" }), digest, verified: /^sha256:[0-9a-f]{64}$/i.test(digest) }] };
    }
  }
  const attempts = [...snapshot.attempts];
  attempts[index] = next;
  return { ...snapshot, attempts, cursor: String(Math.max(Number(snapshot.cursor) || 0, event.sequence)) };
}

function staleCursor(error: unknown): boolean {
  return error instanceof RunApiHttpError && (error.status === 409 || error.status === 410 || error.code === "run_cursor_stale" || error.code === "run_cursor_gap" || error.code === "run_cursor_invalid");
}

/** Snapshot-first replay session. It owns the opaque transport cursor separately from UI state. */
export class RunBoardApiSession {
  private transportCursor: string | undefined;
  private lastSequence = 0;

  constructor(private readonly runId: string, private readonly client: Pick<RunApiClient, "getSnapshot" | "getEvents">) {}

  private async readPages(after?: string): Promise<RunApiEvent[]> {
    const events: RunApiEvent[] = [];
    let cursor = after;
    for (let page = 0; page < 1_000; page += 1) {
      const result = await this.client.getEvents(this.runId, cursor);
      events.push(...result.events);
      const last = result.events.at(-1)?.sequence;
      if (last !== undefined) this.lastSequence = Math.max(this.lastSequence, last);
      if (!result.nextCursor) {
        this.transportCursor = last === undefined ? cursor : encodeCursor(last);
        return events;
      }
      if (result.nextCursor === cursor) throw new RunApiHttpError(409, "event cursor did not advance", "run_cursor_gap");
      cursor = result.nextCursor;
      this.transportCursor = cursor;
    }
    throw new RunApiHttpError(409, "event replay exceeded the page limit", "run_cursor_gap");
  }

  async snapshotAndReplay(): Promise<RunBoardSnapshot> {
    const raw = await this.client.getSnapshot(this.runId);
    let snapshot = normalizeRunSnapshot(raw);
    const embeddedEvents = isSnapshot(raw) || isReceipt(raw) ? (raw.events ?? []) : [];
    this.lastSequence = decodeCursorSequence(isSnapshot(raw) ? raw.cursor : snapshot.cursor) ?? embeddedEvents.at(-1)?.sequence ?? 0;
    this.transportCursor = this.lastSequence > 0
      ? encodeCursor(this.lastSequence)
      : isSnapshot(raw) && raw.cursor
        ? raw.cursor
        : undefined;
    let events = embeddedEvents;
    const replayEvents = await this.readPages(this.transportCursor);
    events = [...events, ...replayEvents];
    for (const event of events) snapshot = applyRunEvent(snapshot, event);
    if (this.lastSequence > 0) snapshot = { ...snapshot, cursor: String(this.lastSequence) };
    return snapshot;
  }

  async replay(current: RunBoardSnapshot): Promise<RunBoardSnapshot> {
    try {
      const events = await this.readPages(this.transportCursor ?? (this.lastSequence > 0 ? encodeCursor(this.lastSequence) : undefined));
      let snapshot = current;
      for (const event of events) snapshot = applyRunEvent(snapshot, event);
      if (this.lastSequence > 0) snapshot = { ...snapshot, cursor: String(this.lastSequence) };
      return snapshot;
    } catch (error) {
      if (!staleCursor(error)) throw error;
      return this.snapshotAndReplay();
    }
  }
}

/** A fixture transport keeps the gallery independent of the HTTP control plane. */
export function createFixtureRunApiClient(initial: RunBoardSnapshot, replay?: RunBoardSnapshot): RunApiClient {
  const events: RunApiEvent[] = [];
  let snapshot = initial;
  return {
    async getSnapshot() {
      const current = snapshot;
      if (replay) snapshot = replay;
      return current;
    },
    async getEvents() {
      return { events, nextCursor: null };
    },
    async createRun() {
      return {
        id: snapshot.id,
        status: "running",
        desiredAttempts: snapshot.attempts.length,
        attempts: snapshot.attempts.map((attempt, ordinal) => ({ id: attempt.id, ordinal, status: "running" })),
        events: [],
      };
    },
    async mintAttachTicket(runId, attemptId) {
      return {
        ticket: `fixture-ticket-${runId}-${attemptId}`,
        runId,
        attemptId,
        provider: "cloud-vm",
        providerVmId: "fixture-vm",
        providerWorkspaceId: "fixture-workspace",
        providerTerminalId: "fixture-terminal",
        expiresAt: new Date(Date.now() + 120_000).toISOString(),
      };
    },
    async redeemAttachTicket(runId, attemptId, ticket) {
      return {
        ticket,
        runId,
        attemptId,
        provider: "cloud-vm",
        providerVmId: "fixture-vm",
        providerWorkspaceId: "fixture-workspace",
        providerTerminalId: "fixture-terminal",
        expiresAt: new Date(Date.now() + 120_000).toISOString(),
        transport: "cmux-remote",
        route: "wss://fixture.invalid/v1/link?ticket=fixture",
        session: `session-${attemptId}`,
      };
    },
    async promoteAttempt(runId, attemptId) {
      return { id: `promotion-${attemptId}`, runId, attemptId, runtime: { id: `runtime-${attemptId}`, state: "ready", sessionId: `session-${attemptId}` } };
    },
  };
}
