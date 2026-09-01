// Ingest endpoint for account-scoped verbose client diagnostics (App Review).
//
// The iOS app streams its privacy-safe DiagnosticLog events (bounded integer
// codes plus a server-renderable summary string, never terminal contents or
// credentials) here only when the signed-in account's Stack
// `clientReadOnlyMetadata` carries `cmuxVerboseDiagnostics: true`. The route
// re-checks that server-written flag on the authenticated user (double gate:
// a client build can never opt itself in), bounds the body and every field,
// and emits one `[cmux-verbose-diag]` log line per event into the Vercel
// runtime logs, the same sink as the per-request lines from
// services/observability/verboseDiagnostics.ts.
//
// Auth + bounded-body shape mirrors web/app/api/analytics/events/route.ts,
// except auth here is REQUIRED (unauthenticated and unflagged uploads are
// rejected) because these lines carry a user id into the log sink.

import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { verifyRequest } from "../../../../services/vms/auth";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import { withApiRouteSpan } from "../../../../services/telemetry";
import { emitVerboseDiagnosticsLog } from "../../../../services/observability/verboseDiagnostics";

export const MAX_DIAGNOSTICS_REQUEST_BYTES = 256 * 1024;
export const MAX_DIAGNOSTICS_BATCH_EVENTS = 256;
const MAX_SUMMARY_CHARS = 300;
const MAX_NAME_CHARS = 80;
const MAX_TIMESTAMP_CHARS = 40;
const MAX_BUILD_STAMP_CHARS = 96;
const MAX_CLIENT_ID_CHARS = 64;

type DiagnosticsIngestDependencies = {
  readonly verifyRequest: (
    request: Request,
    options: { readonly allowCookie: false },
  ) => Promise<
    | { readonly id: string; readonly verboseDiagnostics?: boolean }
    | null
  >;
};

const defaultDependencies: DiagnosticsIngestDependencies = { verifyRequest };

type IncomingDiagnosticEvent = {
  readonly at?: string;
  readonly code: number;
  readonly name?: string;
  readonly summary?: string;
  readonly surface?: number;
  readonly ms?: number;
  readonly a?: number;
  readonly b?: number;
  readonly c?: number;
};

export const POST = makeDiagnosticsIngestHandler();

export function makeDiagnosticsIngestHandler(
  dependencies: DiagnosticsIngestDependencies = defaultDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    return withApiRouteSpan(
      request,
      "/api/diagnostics/ingest",
      { "cmux.subsystem": "diagnostics" },
      async () => {
        const user = await dependencies.verifyRequest(request, {
          allowCookie: false,
        });
        if (!user) {
          return jsonResponse({ error: "unauthorized" }, 401);
        }
        // Server-side double gate: the flag is server-written metadata read
        // fresh (or from the short-lived auth cache) on this request. A client
        // that uploads without it (stale build, tampered client) is
        // rejected regardless of what its local state believes.
        if (user.verboseDiagnostics !== true) {
          return jsonResponse({ error: "diagnostics_not_enabled" }, 403);
        }

        const body = await readBoundedJsonObject(
          request,
          MAX_DIAGNOSTICS_REQUEST_BYTES,
        );
        if (!body.ok) {
          return jsonResponse(
            { error: body.error },
            body.error === "request_too_large" ? 413 : 400,
          );
        }

        const rawBatch = body.value.batch;
        if (!Array.isArray(rawBatch)) {
          return jsonResponse({ error: "missing_batch" }, 400);
        }
        if (rawBatch.length > MAX_DIAGNOSTICS_BATCH_EVENTS) {
          return jsonResponse({ error: "batch_too_large" }, 400);
        }

        const buildStamp = boundedString(body.value.buildStamp, MAX_BUILD_STAMP_CHARS);
        const clientId = boundedString(body.value.clientId, MAX_CLIENT_ID_CHARS);

        const accepted: IncomingDiagnosticEvent[] = [];
        for (const candidate of rawBatch) {
          const sanitized = sanitizeDiagnosticEvent(candidate);
          if (sanitized) accepted.push(sanitized);
        }

        for (const event of accepted) {
          emitVerboseDiagnosticsLog("client_event", {
            userId: user.id,
            deviceId: clientId,
            clientAt: event.at,
            code: event.code,
            name: event.name,
            summary: event.summary,
            surface: event.surface,
            ms: event.ms,
            a: event.a,
            b: event.b,
            c: event.c,
            buildStamp,
          });
        }
        emitVerboseDiagnosticsLog("client_batch", {
          userId: user.id,
          deviceId: clientId,
          received: rawBatch.length,
          accepted: accepted.length,
          buildStamp,
        });

        return jsonResponse({ ok: true, accepted: accepted.length }, 202);
      },
    );
  };
}

function sanitizeDiagnosticEvent(
  candidate: unknown,
): IncomingDiagnosticEvent | null {
  if (
    candidate === null ||
    typeof candidate !== "object" ||
    Array.isArray(candidate)
  ) {
    return null;
  }
  const record = candidate as Record<string, unknown>;
  const code = boundedInteger(record.code);
  if (code === undefined) return null;
  return {
    at: boundedString(record.at, MAX_TIMESTAMP_CHARS),
    code,
    name: boundedString(record.name, MAX_NAME_CHARS),
    summary: boundedString(record.summary, MAX_SUMMARY_CHARS),
    surface: boundedInteger(record.surface),
    ms: boundedInteger(record.ms),
    a: boundedInteger(record.a),
    b: boundedInteger(record.b),
    c: boundedInteger(record.c),
  };
}

function boundedInteger(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    return undefined;
  }
  return value;
}

/**
 * Bounds client-supplied text before it enters the log sink: control
 * characters (line splitting, ANSI) are stripped so one event is always one
 * log line, and length is capped.
 */
function boundedString(value: unknown, maxChars: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const cleaned = [...value]
    .filter((char) => {
      const codePoint = char.codePointAt(0) ?? 0;
      return codePoint >= 0x20 && codePoint !== 0x7f;
    })
    .join("");
  if (!cleaned) return undefined;
  return cleaned.length > maxChars ? `${cleaned.slice(0, maxChars)}…` : cleaned;
}
