// Attach/detach report sink for the self-hosted relay fleet (cmux-relay
// `Reporter`): fire-and-forget HMAC-signed POSTs of
// `{endpointId, event, relayId, ts}` on every admitted connect and every
// disconnect. Applying one publishes "endpoint X reachable via relay Y" into
// the registry, which discovery serves to the account's other devices — the
// server-side replacement for the Mac's client-side post-attach republish.
//
// Hardening mirrors /api/relay/allow: shared-secret HMAC over the raw body
// (fail closed to 503 when the secret is unset), bounded body read with a
// hard deadline, a response-latency bound on the database application, a
// dedicated deadline-bounded connection pool, a hard concurrency cap, and
// `cache-control: no-store` on every response. The relay treats any non-2xx
// as a logged warning, never a retry loop, so degraded answers are safe.

import { env } from "../../../env";
import { jsonResponse, readBoundedBody } from "../../../../services/relay/http";
import {
  parseRelayAllowSecret,
  verifyRelayAllowSignature,
} from "../../../../services/relay/allow";
import {
  RELAY_REPORT_SIGNATURE_HEADER,
  RelayReportSaturatedError,
  applyRelayAttachReport,
  parseRelayAttachReport,
  type RelayAttachReport,
  type RelayReportOutcome,
} from "../../../../services/relay/report";

const MAX_BODY_BYTES = 4 * 1_024;
const BODY_READ_TIMEOUT_MS = 5_000;
// Response-latency bound for the registry update, so a stalled database
// cannot hold report handlers (and their concurrency slots) until some
// external timeout. Expiry fails to 503; the next attach/detach event
// self-heals the published state. The resource bounds live in
// services/relay/report.ts (statement timeout, settle bound, dedicated pool,
// concurrency cap).
const APPLY_TIMEOUT_MS = 3_000;

export interface RelayReportDeps {
  readonly secretBase64: () => string | undefined;
  readonly apply: (report: RelayAttachReport) => Promise<RelayReportOutcome>;
  readonly applyTimeoutMs?: number;
  readonly bodyReadTimeoutMs?: number;
  readonly now?: () => Date;
}

const productionDeps: RelayReportDeps = {
  secretBase64: () => env.CMUX_RELAY_ALLOW_HMAC_SECRET_B64,
  apply: applyRelayAttachReport,
};

export async function handleRelayReportRequest(
  request: Request,
  deps: RelayReportDeps,
): Promise<Response> {
  const secret = parseRelayAllowSecret(deps.secretBase64());
  if (!secret) return jsonResponse({ error: "relay_report_not_configured" }, 503);

  const body = await readBoundedBody(request, {
    maxBytes: MAX_BODY_BYTES,
    timeoutMs: deps.bodyReadTimeoutMs ?? BODY_READ_TIMEOUT_MS,
  });
  if (!body.ok) return body.response;

  // Reports always carry the signature header (the relay signs the exact
  // body bytes); no bearer fallback exists on this route.
  const provided = request.headers.get(RELAY_REPORT_SIGNATURE_HEADER)?.trim();
  if (!provided || !verifyRelayAllowSignature(secret, body.bytes, provided)) {
    return jsonResponse({ error: "invalid_relay_report_signature" }, 401);
  }

  if (body.bytes.byteLength === 0) {
    return jsonResponse({ error: "missing_report_body" }, 400);
  }
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(body.bytes).toString("utf8"));
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const parsed = parseRelayAttachReport(value, (deps.now ?? (() => new Date()))());
  if (!parsed.ok) return jsonResponse({ error: parsed.error }, 400);

  try {
    return outcomeResponse(await applyWithDeadline(deps, parsed.report));
  } catch (error) {
    if (error instanceof RelayReportSaturatedError) {
      return jsonResponse({ error: "relay_report_saturated" }, 503);
    }
    // Never log EndpointIDs; the route and failure class are enough.
    console.error("relay report application failed", { failure: "unexpected" });
    return jsonResponse({ error: "relay_report_unavailable" }, 503);
  }
}

async function applyWithDeadline(
  deps: RelayReportDeps,
  report: RelayAttachReport,
): Promise<RelayReportOutcome> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const application = deps.apply(report);
  // An application that settles (typically rejecting on the database-side
  // statement_timeout) after losing the race must not surface as an
  // unhandled rejection.
  application.catch(() => undefined);
  try {
    return await Promise.race([
      application,
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("relay_report_apply_timeout")),
          deps.applyTimeoutMs ?? APPLY_TIMEOUT_MS,
        );
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function outcomeResponse(outcome: RelayReportOutcome): Response {
  switch (outcome) {
    case "applied":
      return jsonResponse({ applied: true });
    case "superseded":
    case "unknown_endpoint":
      // Stale orderings and reports about endpoints that no longer have an
      // active binding are normal fleet operation, not caller errors.
      return jsonResponse({ applied: false, reason: outcome });
    case "untrusted_relay":
      // A syntactically valid, correctly signed report about a relay outside
      // the account's dialable set: refuse loudly so the relay's warn log
      // shows the misconfiguration (e.g. a dev relay pointed at production).
      return jsonResponse({ error: "untrusted_relay" }, 403);
  }
}

export function POST(request: Request): Promise<Response> {
  return handleRelayReportRequest(request, productionDeps);
}
