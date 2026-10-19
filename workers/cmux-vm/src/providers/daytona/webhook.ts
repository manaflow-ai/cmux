import { Effect, Redacted } from "effect";
import { verifyWebhookSignature } from "../../auth/webhook-signature.ts";
import type { UsageEvent } from "../../metering/recorder.ts";

const MAX_BODY_BYTES = 64 * 1024;
const REPLAY_WINDOW_MS = 5 * 60 * 1000;

export interface DaytonaUsageResource {
  readonly tenantId: string;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb: number;
}

export interface DaytonaWebhookConfig {
  readonly secret: Redacted.Redacted<string>;
  /** Resolves the ownership row and current resources without trusting webhook tenant fields. */
  readonly resolveSandbox: (upstreamVmId: string) => Promise<DaytonaUsageResource | null>;
  readonly recorder?: { readonly record: (event: UsageEvent) => Effect.Effect<void> };
  readonly nowMs?: () => number;
}

const response = (status: number, body: Record<string, unknown>): Response => Response.json(body, { status });

const bodyObject = (value: unknown): Record<string, unknown> | null => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
};

const stringField = (object: Record<string, unknown>, key: string): string | null => (typeof object[key] === "string" ? object[key] : null);

const eventAt = (object: Record<string, unknown>, nowMs: number): Date => {
  const raw = stringField(object, "updatedAt") ?? stringField(object, "timestamp");
  if (raw === null) return new Date(nowMs);
  const at = new Date(raw);
  return Number.isNaN(at.getTime()) ? new Date(nowMs) : at;
};

const cleanup = (seen: Map<string, number>, nowMs: number): void => {
  for (const [id, at] of seen) if (nowMs - at > REPLAY_WINDOW_MS) seen.delete(id);
};

const eventFor = (payload: Record<string, unknown>, resource: DaytonaUsageResource, at: Date): UsageEvent | null => {
  const oldState = stringField(payload, "oldState");
  const newState = stringField(payload, "newState");
  const upstreamVmId = stringField(payload, "id");
  if (upstreamVmId === null || newState === null) return null;
  if (newState === "started" && oldState === "resizing") {
    return { kind: "vm_resized", tenantId: resource.tenantId, upstreamVmId, at, vcpus: resource.vcpus, memoryMb: resource.memoryMb, storageMb: resource.storageMb };
  }
  if (newState === "started") {
    return { kind: "vm_started", tenantId: resource.tenantId, upstreamVmId, at, vcpus: resource.vcpus, memoryMb: resource.memoryMb, storageMb: resource.storageMb };
  }
  if (newState === "paused") return { kind: "vm_stopped", tenantId: resource.tenantId, upstreamVmId, at, reason: "pause" };
  if (newState === "destroyed") return { kind: "vm_stopped", tenantId: resource.tenantId, upstreamVmId, at, reason: "delete" };
  if (newState === "stopped") return { kind: "vm_stopped", tenantId: resource.tenantId, upstreamVmId, at, reason: "stop" };
  return null;
};

/** Creates a signed Daytona webhook handler. Svix delivery ids are replay-protected in this isolate. */
export const makeDaytonaWebhookHandler = (config: DaytonaWebhookConfig) => {
  const seen = new Map<string, number>();
  return (request: Request): Effect.Effect<Response> =>
    Effect.gen(function* () {
      if (request.method !== "POST") return response(405, { _tag: "MethodNotAllowed", message: "Use POST" });
      const declared = Number(request.headers.get("content-length") ?? "0");
      if (declared > MAX_BODY_BYTES) return response(413, { _tag: "PayloadTooLarge", message: "Webhook body too large" });
      const body = yield* Effect.tryPromise(() => request.text());
      if (body.length > MAX_BODY_BYTES) return response(413, { _tag: "PayloadTooLarge", message: "Webhook body too large" });
      const nowMs = config.nowMs?.() ?? Date.now();
      const signature = yield* Effect.tryPromise(() => verifyWebhookSignature(config.secret, request.headers, body, nowMs));
      if (!signature.ok) return response(401, { _tag: "Unauthorized", message: "Invalid webhook signature" });
      cleanup(seen, nowMs);
      if (seen.has(signature.messageId)) return response(200, { ok: true, duplicate: true });
      seen.set(signature.messageId, nowMs);
      let parsed: unknown;
      try {
        parsed = JSON.parse(body) as unknown;
      } catch {
        return response(400, { _tag: "BadRequest", message: "Malformed webhook body" });
      }
      const payload = bodyObject(parsed);
      if (payload === null) return response(400, { _tag: "BadRequest", message: "Malformed webhook body" });
      if (stringField(payload, "event") !== "sandbox.state.updated") return response(200, { ok: true, ignored: true });
      const upstreamVmId = stringField(payload, "id");
      if (upstreamVmId === null) return response(400, { _tag: "BadRequest", message: "Malformed sandbox event" });
      const resource = yield* Effect.tryPromise(() => config.resolveSandbox(upstreamVmId));
      if (resource === null) return response(200, { ok: true, ignored: true });
      const event = eventFor(payload, resource, eventAt(payload, nowMs));
      if (event === null) return response(200, { ok: true, ignored: true });
      if (config.recorder !== undefined) yield* config.recorder.record(event);
      return response(200, { ok: true, recorded: event.kind });
    });
};

/** One-shot form used by the wave-2 route composition root. */
export const handleDaytonaWebhook = (request: Request, config: DaytonaWebhookConfig): Effect.Effect<Response> => makeDaytonaWebhookHandler(config)(request);
