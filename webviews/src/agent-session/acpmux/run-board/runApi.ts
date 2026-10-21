import { translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import type { AttachTicket, RunArtifact, RunAttempt, RunBoardSnapshot } from "./model";
export type { AttachTicket } from "./model";

/** The JSON shape returned by the Run control plane. */
export type RunApiRun = {
  id: string;
  userId?: string;
  source: { repository?: string; ref?: string; commit?: string; archiveDigest?: string };
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
  status: string;
  providerVmId?: string | null;
  /** The Run view's stable placement (`/api/runs/[id]`); it never carries provider handles. */
  placement?: { sessionId?: string | null } | null;
  /** Whether the attempt's terminal is retained and an attach ticket can be minted for it. */
  attachable?: boolean;
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
  /** A future API may include the event cursor captured by the snapshot. */
  cursor?: string;
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

export type AttachTicketIntent = {
  runId: string;
  attemptId: string;
  sessionId: string;
  cursor: string;
};

/**
 * The one-use capability returned by the Run attach route.  The control plane
 * currently returns the opaque `ticket` plus the attempt identity; the
 * optional transport fields let the host bridge carry a provider endpoint
 * without making the board understand how to dial it.
 */
export type RunAttachTicket = AttachTicket & {
  transport?: string;
  route?: string;
  token?: string;
  session?: string;
  trustedCarrier?: boolean;
  endpoint?: {
    transport?: string;
    route?: string;
    token?: string;
    session?: string;
    trustedCarrier?: boolean;
    expiresAtUnix?: number;
  };
  provider?: string;
  providerVmId?: string;
  providerWorkspaceId?: string;
  providerTerminalId?: string;
};

export type RunApiClient = {
  getSnapshot(runId: string): Promise<RunApiSnapshot | RunBoardSnapshot>;
  getEvents(runId: string, after?: string): Promise<RunApiEventPage>;
  /** Mint a short-lived, one-use terminal attach capability for an attempt. */
  requestAttachTicket?: (intent: AttachTicketIntent) => Promise<RunAttachTicket>;
};

/** The part of `fetch` the client uses, so tests can pass a plain function. */
export type RunApiFetch = (input: string, init?: RequestInit) => Promise<Response>;

export type RunApiClientOptions = {
  baseUrl?: string;
  fetch?: RunApiFetch;
  headers?: Record<string, string>;
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

function attachTicketFromResponse(value: unknown, intent: AttachTicketIntent): RunAttachTicket {
  const outer = record(value);
  // Accept both the direct response and the `{ attachTicket: ... }` envelope
  // used by the server route during its rollout.  Keeping this tolerant makes
  // deploys with an older edge and a newer board reconnect cleanly.
  const nested = record(outer.attachTicket ?? outer.attach_ticket ?? outer.attach ?? value);
  const endpoint = record(nested.endpoint ?? outer.endpoint);
  const ticket = stringValue(nested.ticket) ?? stringValue(outer.ticket);
  const runId = stringValue(nested.runId) ?? stringValue(nested.run_id) ?? intent.runId;
  const attemptId = stringValue(nested.attemptId) ?? stringValue(nested.attempt_id) ?? intent.attemptId;
  const sessionId = stringValue(nested.sessionId) ?? stringValue(nested.session_id) ?? intent.sessionId;
  const cursor = stringValue(nested.cursor) ?? intent.cursor;
  if (!ticket || !runId || !attemptId || !sessionId || !cursor) {
    throw new RunApiHttpError(502, translate("runBoard.error.attachInvalidTicket"), "run_attach_invalid");
  }
  const expiresAt = nested.expiresAt ?? nested.expires_at;
  const expiresAtUnix = nested.expiresAtUnix ?? nested.expires_at_unix;
  const optionalString = (key: string, snake: string = key) =>
    stringValue(nested[key]) ??
    stringValue(nested[snake]) ??
    stringValue(endpoint[key]) ??
    stringValue(endpoint[snake]);
  const transport = optionalString("transport");
  const route = optionalString("route");
  const tokenValue = optionalString("token");
  const session = optionalString("session");
  const trustedCarrier =
    nested.trustedCarrier ?? nested.trusted_carrier ?? endpoint.trustedCarrier ?? endpoint.trusted_carrier;
  const endpointExpiresAtUnix = endpoint.expiresAtUnix ?? endpoint.expires_at_unix;
  return {
    runId,
    attemptId,
    sessionId,
    cursor,
    ticket,
    ...(typeof expiresAt === "string" || typeof expiresAt === "number" ? { expiresAt } : {}),
    ...(typeof expiresAtUnix === "number" ? { expiresAtUnix } : {}),
    ...(transport ? { transport } : {}),
    ...(route ? { route } : {}),
    ...(tokenValue ? { token: tokenValue } : {}),
    ...(session ? { session } : {}),
    ...(typeof trustedCarrier === "boolean" ? { trustedCarrier } : {}),
    ...(Object.keys(endpoint).length
      ? {
          endpoint: {
            ...(transport ? { transport } : {}),
            ...(route ? { route } : {}),
            ...(tokenValue ? { token: tokenValue } : {}),
            ...(session ? { session } : {}),
            ...(typeof trustedCarrier === "boolean" ? { trustedCarrier } : {}),
            ...(typeof endpointExpiresAtUnix === "number" ? { expiresAtUnix: endpointExpiresAtUnix } : {}),
          },
        }
      : {}),
    ...(optionalString("provider") ? { provider: optionalString("provider") } : {}),
    ...(optionalString("providerVmId", "provider_vm_id")
      ? { providerVmId: optionalString("providerVmId", "provider_vm_id") }
      : {}),
    ...(optionalString("providerWorkspaceId", "provider_workspace_id")
      ? { providerWorkspaceId: optionalString("providerWorkspaceId", "provider_workspace_id") }
      : {}),
    ...(optionalString("providerTerminalId", "provider_terminal_id")
      ? { providerTerminalId: optionalString("providerTerminalId", "provider_terminal_id") }
      : {}),
  };
}

/** Same-origin HTTP transport used by the real Run board. */
export function createRunApiClient(options: RunApiClientOptions = {}): RunApiClient {
  const request: RunApiFetch = options.fetch ?? ((input, init) => globalThis.fetch(input, init));
  const baseUrl = apiOrigin(options.baseUrl);
  const headers: Record<string, string> = { Accept: "application/json", ...options.headers };
  return {
    async getSnapshot(runId) {
      const response = await request(apiUrl(baseUrl, `/api/runs/${encodeURIComponent(runId)}`), {
        credentials: "same-origin",
        headers,
      });
      const body = await readJson(response);
      if (!response.ok) {
        const error = body as { error?: string; message?: string };
        throw new RunApiHttpError(
          response.status,
          error.message ?? translate("runBoard.error.snapshotFailed", { status: response.status }),
          error.error,
        );
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
      if (!response.ok) {
        const error = body as { error?: string; message?: string };
        throw new RunApiHttpError(
          response.status,
          error.message ?? translate("runBoard.error.eventsFailed", { status: response.status }),
          error.error,
        );
      }
      const result = body as Partial<RunApiEventPage>;
      return { events: Array.isArray(result.events) ? result.events : [], nextCursor: result.nextCursor ?? null };
    },
    async requestAttachTicket(intent) {
      const path = `/api/runs/${encodeURIComponent(intent.runId)}/attempts/${encodeURIComponent(intent.attemptId)}/attach-ticket`;
      const response = await request(apiUrl(baseUrl, path), {
        method: "POST",
        credentials: "same-origin",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ sessionId: intent.sessionId, cursor: intent.cursor }),
      });
      const body = await readJson(response);
      if (!response.ok) {
        const error = body as { error?: string; code?: string; message?: string };
        throw new RunApiHttpError(
          response.status,
          error.message ?? translate("runBoard.error.attachFailed", { status: response.status }),
          error.code ?? error.error,
        );
      }
      const minted = attachTicketFromResponse(body, intent);
      const redeemedResponse = await request(apiUrl(baseUrl, path), {
        method: "POST",
        credentials: "same-origin",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ ticket: minted.ticket }),
      });
      const redeemedBody = await readJson(redeemedResponse);
      if (!redeemedResponse.ok) {
        const error = redeemedBody as { error?: string; code?: string; message?: string };
        throw new RunApiHttpError(
          redeemedResponse.status,
          error.message ?? translate("runBoard.error.attachRedeemFailed", { status: redeemedResponse.status }),
          error.code ?? error.error,
        );
      }
      return attachTicketFromResponse({ ...record(redeemedBody), ...minted }, intent);
    },
  };
}

function encodeCursor(sequence: number): string {
  return encodeBase64Url(JSON.stringify({ sequence }));
}

function encodeBase64Url(value: string): string {
  if (typeof btoa === "function") return btoa(value).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  return Buffer.from(value, "utf8").toString("base64url");
}

function isSnapshot(value: RunApiSnapshot | RunBoardSnapshot): value is RunApiSnapshot {
  return "run" in value && typeof value.run === "object";
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
  return {
    id: attempt.id,
    label: stringValue(resultValue(result, "label")) ?? `Attempt ${String.fromCharCode(65 + attempt.ordinal)}`,
    direction: stringValue(resultValue(result, "direction")) ?? `Independent review ${attempt.ordinal + 1}`,
    worker: `${stringValue(resultValue(result, "provider")) ?? "cloud-vm"}${providerVmId ? ` · ${providerVmId}` : ""}`,
    sessionId:
      stringValue(resultValue(result, "sessionId")) ??
      stringValue(attempt.placement?.sessionId) ??
      providerVmId ??
      attempt.id,
    ...(typeof attempt.attachable === "boolean" ? { attachable: attempt.attachable } : {}),
    state,
    activity:
      stringValue(resultValue(result, "activity")) ??
      (state === "completed"
        ? "Finished. Ready for your review."
        : state === "failed"
          ? (attempt.error ?? "Attempt failed.")
          : "Working on the shared intent."),
    build:
      buildValue === "failed" || state === "failed"
        ? "failed"
        : buildValue === "passed" || state === "completed"
          ? "passed"
          : "pending",
    tests: { passed, failed },
    artifacts: artifacts.filter((item) => item.attemptId === attempt.id).map(mapArtifact),
    rows: rowsFromResult(result),
  };
}

export function normalizeRunSnapshot(value: RunApiSnapshot | RunBoardSnapshot): RunBoardSnapshot {
  if (!isSnapshot(value)) return value;
  const source = value.run.source ?? {};
  const commit = source.commit ? ` @ ${source.commit.slice(0, 12)}` : "";
  return {
    id: value.run.id,
    title: `Run ${value.run.id.slice(0, 8)}`,
    intent: `${value.run.recipe} on ${source.repository ?? "the attached repository"}${commit}`,
    source: `${source.repository ?? "repository"}${commit}`,
    cursor: value.cursor ?? "0",
    attempts: value.attempts.map((attempt) => mapAttempt(attempt, value.artifacts)),
  };
}

function eventText(event: RunApiEvent): string | undefined {
  const payload = record(event.payload);
  return (
    stringValue(payload.text) ??
    stringValue(payload.output) ??
    stringValue(payload.message) ??
    stringValue(payload.error)
  );
}

function appendEventRow(attempt: RunAttempt, event: RunApiEvent): RunAttempt {
  const text = eventText(event);
  if (!text) return attempt;
  const at = event.createdAt ? Date.parse(event.createdAt) : Date.now();
  const title = translate("runBoard.agentOutput");
  const row: AcpmuxRow =
    event.kind === "attempt.output"
      ? {
          id: event.id,
          version: 1,
          at,
          kind: "activity",
          items: [
            {
              kind: "tool",
              text: title,
              tool: { id: event.id, title, kind: "execute", status: "completed", output: text },
            },
          ],
        }
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
    next = {
      ...next,
      state: "running",
      worker: providerVmId ? `cloud-vm · ${providerVmId}` : next.worker,
      sessionId: providerVmId ?? next.sessionId,
      activity: "Agent started.",
    };
  } else if (event.kind === "attempt.succeeded") {
    next = { ...next, state: "completed", build: "passed", activity: "Finished. Ready for your review." };
  } else if (event.kind === "attempt.failed") {
    next = { ...next, state: "failed", build: "failed", activity: eventText(event) ?? "Attempt failed." };
  } else if (event.kind === "attempt.artifact") {
    const digest = stringValue(payload.digest);
    const name = stringValue(payload.name);
    if (digest && name && !next.artifacts.some((artifact) => artifact.digest === digest || artifact.name === name)) {
      next = {
        ...next,
        artifacts: [
          ...next.artifacts,
          {
            id: stringValue(payload.artifactId) ?? `${event.id}-artifact`,
            name,
            kind: artifactKind({
              id: "",
              attemptId: current.id,
              name,
              sizeBytes: numberValue(payload.sizeBytes) ?? 0,
              digest,
              uri: "artifact://event",
            }),
            digest,
            verified: /^sha256:[0-9a-f]{64}$/i.test(digest),
          },
        ],
      };
    }
  }
  const attempts = [...snapshot.attempts];
  attempts[index] = next;
  return { ...snapshot, attempts, cursor: String(Math.max(Number(snapshot.cursor) || 0, event.sequence)) };
}

function staleCursor(error: unknown): boolean {
  return (
    error instanceof RunApiHttpError &&
    (error.status === 409 ||
      error.status === 410 ||
      error.code === "run_cursor_stale" ||
      error.code === "run_cursor_gap" ||
      error.code === "run_cursor_invalid")
  );
}

/** Snapshot-first replay session. It owns the opaque transport cursor separately from UI state. */
export class RunBoardApiSession {
  private transportCursor: string | undefined;
  private lastSequence = 0;

  constructor(
    readonly runId: string,
    private readonly client: RunApiClient,
  ) {}

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
      if (result.nextCursor === cursor)
        throw new RunApiHttpError(409, translate("runBoard.error.cursorStalled"), "run_cursor_gap");
      cursor = result.nextCursor;
      this.transportCursor = cursor;
    }
    throw new RunApiHttpError(409, translate("runBoard.error.replayPageLimit"), "run_cursor_gap");
  }

  async snapshotAndReplay(): Promise<RunBoardSnapshot> {
    const raw = await this.client.getSnapshot(this.runId);
    let snapshot = normalizeRunSnapshot(raw);
    this.lastSequence = Number(snapshot.cursor) || 0;
    this.transportCursor = undefined;
    const events = await this.readPages();
    for (const event of events) snapshot = applyRunEvent(snapshot, event);
    if (this.lastSequence > 0) snapshot = { ...snapshot, cursor: String(this.lastSequence) };
    return snapshot;
  }

  async replay(current: RunBoardSnapshot): Promise<RunBoardSnapshot> {
    try {
      const events = await this.readPages(
        this.transportCursor ?? (this.lastSequence > 0 ? encodeCursor(this.lastSequence) : undefined),
      );
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
  };
}
