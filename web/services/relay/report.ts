// Backend half of the relay fleet's attach/detach reporting (cmux-relay
// `Reporter`, manaflow-ai/cmux-relay PR #9). On every admitted connect the
// relay fire-and-forgets `POST CMUX_RELAY_REPORT_URL` with the JSON body
// `{endpointId, event: "attach"|"detach", relayId, ts}`, signed exactly like
// allow-hook calls: unpadded base64url HMAC-SHA256 over the raw body bytes in
// the same `x-cmux-relay-allow-signature` header, same shared secret
// (CMUX_RELAY_ALLOW_HMAC_SECRET_B64). `relayId` is the relay's public
// hostname (its `--hostname` flag, e.g. `usc1.relay.cmux.dev`); `ts` is the
// relay-side event time in unix milliseconds.
//
// Applying a report publishes "endpoint X is reachable via relay Y" into the
// registry (`iroh_endpoint_bindings.relay_attached_url`), which discovery
// serves to the account's other devices as a server-observed relay hint —
// replacing the Mac's client-side post-attach republish.
//
// Trust decision: the HMAC proves a fleet relay (holder of the shared
// secret) sent the report, but `relayId` inside the body is self-declared,
// so a single compromised relay — or a leaked secret — could otherwise
// publish an attacker-controlled relay URL to every phone on any account.
// An ATTACH is therefore only applied when its hostname resolves to a relay
// the account is already allowed to dial: an exact managed-catalog URL, or a
// custom relay the account has saved (matched by hostname, publishing the
// saved URL verbatim). Every other attach is rejected (`untrusted_relay`),
// which also keeps dev relays (`cmux-relay-dev`) out of production state.
// A DETACH clears state instead of publishing it, so it is matched against
// the stored URL by hostname without the trust lookup — see
// `applyRelayAttachReport`.
// Debug/test fleets get trusted the same way: their relay must be in the
// catalog the deployment was built with, or saved as that account's custom
// relay; the HMAC alone is deliberately NOT sufficient.
//
// Ordering: reports are fire-and-forget and can arrive out of order, so each
// applied report records its relay-side event timestamp and older events are
// dropped (`superseded`). Attach wins a timestamp tie (make-before-break
// reconnects admit the new connection before the old one closes). Known
// residual: the report body carries no connection id, so a same-relay
// reconnect whose old-connection detach lands after the new-connection
// attach (with a later relay-side ts) unpublishes the route until the next
// attach event; the client republish fallback covers that window, and fixing
// it properly needs a connection id in the relay's report body.
//
// Unlike /api/relay/allow this path does not consult account-deletion
// tombstones: deletion revokes bindings (which hides them from discovery and
// denies relay admission), so attach state on a to-be-deleted account is
// unreachable either way.

import { RELAY_ALLOW_SIGNATURE_HEADER } from "./allow";
import { MANAGED_IROH_RELAY_CATALOG } from "./generated/managedRelayCatalog";
import { closeRelayHookDbClientForTests, relayHookDbClient } from "./hookDb";

/** Same header, same signing scheme, same secret as the allow hook. */
export const RELAY_REPORT_SIGNATURE_HEADER = RELAY_ALLOW_SIGNATURE_HEADER;

/**
 * Hard cap on concurrently running report applications per runtime instance,
 * and the size of the dedicated report pool (separate from the admission
 * pool, so report bursts can never starve connection admissions). A
 * saturated instance answers 503; the relay treats any failure as
 * best-effort and the next attach/detach event self-heals the state.
 */
export const RELAY_REPORT_MAX_CONCURRENT = 16;

export const RELAY_REPORT_STATEMENT_TIMEOUT_MS = 2_500;
export const RELAY_REPORT_SETTLE_MS = 4_000;

/**
 * Reject event timestamps this far ahead of server time. Without the bound a
 * relay with a runaway clock would plant a far-future `relay_attach_reported_at`
 * that blocks every later (correctly timed) report for the endpoint.
 */
export const RELAY_REPORT_MAX_FUTURE_SKEW_MS = 5 * 60 * 1_000;

const ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;
// RFC 1123 hostname labels, lowercase; total length bounded below.
const RELAY_HOSTNAME_RE =
  /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
const MAX_RELAY_HOSTNAME_LENGTH = 253;

export class RelayReportSaturatedError extends Error {
  constructor() {
    super("relay report concurrency saturated");
    this.name = "RelayReportSaturatedError";
  }
}

let inFlightReports = 0;

/** Runs one report application under the concurrency cap; rejects when saturated. */
export async function withRelayReportSlot<T>(
  operation: () => Promise<T>,
): Promise<T> {
  if (inFlightReports >= RELAY_REPORT_MAX_CONCURRENT) {
    throw new RelayReportSaturatedError();
  }
  inFlightReports += 1;
  try {
    return await operation();
  } finally {
    inFlightReports -= 1;
  }
}

export type RelayAttachReport = {
  readonly endpointId: string;
  readonly event: "attach" | "detach";
  readonly relayId: string;
  /** Relay-side event time (body `ts`, unix milliseconds). */
  readonly reportedAt: Date;
};

export type RelayReportParseError =
  | "invalid_report_body"
  | "invalid_endpoint_id"
  | "invalid_report_event"
  | "invalid_relay_id"
  | "invalid_report_time";

export type RelayReportParseResult =
  | { readonly ok: true; readonly report: RelayAttachReport }
  | { readonly ok: false; readonly error: RelayReportParseError };

export function parseRelayAttachReport(
  value: unknown,
  now: Date,
): RelayReportParseResult {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "invalid_report_body" };
  }
  const record = value as Record<string, unknown>;
  const allowed = new Set(["endpointId", "event", "relayId", "ts"]);
  if (Object.keys(record).some((key) => !allowed.has(key))) {
    return { ok: false, error: "invalid_report_body" };
  }

  const endpointId = typeof record.endpointId === "string"
    ? record.endpointId.trim().toLowerCase()
    : "";
  if (!ENDPOINT_ID_RE.test(endpointId)) {
    return { ok: false, error: "invalid_endpoint_id" };
  }

  const event = record.event;
  if (event !== "attach" && event !== "detach") {
    return { ok: false, error: "invalid_report_event" };
  }

  const relayId = typeof record.relayId === "string"
    ? record.relayId.trim().toLowerCase()
    : "";
  if (
    relayId.length === 0 ||
    relayId.length > MAX_RELAY_HOSTNAME_LENGTH ||
    !RELAY_HOSTNAME_RE.test(relayId)
  ) {
    return { ok: false, error: "invalid_relay_id" };
  }

  const ts = record.ts;
  if (
    typeof ts !== "number" ||
    !Number.isSafeInteger(ts) ||
    ts <= 0 ||
    ts > now.getTime() + RELAY_REPORT_MAX_FUTURE_SKEW_MS
  ) {
    return { ok: false, error: "invalid_report_time" };
  }

  return {
    ok: true,
    report: { endpointId, event, relayId, reportedAt: new Date(ts) },
  };
}

/**
 * Resolves a reported relay hostname to the exact URL the registry may
 * publish: the managed catalog first, then the account's saved custom relays
 * (their saved URL verbatim, so ports survive). Returns null for hostnames
 * the account is not allowed to dial.
 */
export function publishableRelayURLForHostname(
  relayId: string,
  savedCustomRelayURLs: readonly string[],
): string | null {
  for (const relay of MANAGED_IROH_RELAY_CATALOG.relays) {
    if (urlHostname(relay.url) === relayId) return relay.url;
  }
  // Deterministic pick if several saved relays share one hostname.
  for (const saved of [...savedCustomRelayURLs].sort()) {
    if (urlHostname(saved) === relayId) return saved;
  }
  return null;
}

function urlHostname(value: string): string | null {
  try {
    return new URL(value).hostname.toLowerCase();
  } catch {
    return null;
  }
}

export type RelayReportOutcome =
  | "applied"
  | "superseded"
  | "unknown_endpoint"
  | "untrusted_relay";

// The active binding for the endpoint (with its current attachment) plus
// that account's saved custom relays (preferences are keyed by the same
// Stack user id bindings carry). The partial unique index
// `iroh_endpoint_bindings_active_endpoint_unique` guarantees at most one row.
const REPORT_CONTEXT_SQL = `
  select
    binding.user_id as "userId",
    binding.relay_attached_url as "attachedUrl",
    pref.custom_relays as "customRelays"
  from iroh_endpoint_bindings binding
  left join iroh_relay_preferences pref
    on pref.account_id = binding.user_id
  where binding.endpoint_id = $1
    and binding.revoked_at is null
  limit 1
`;

// Ordering guards: an attach applies unless a strictly newer event was
// already applied (attach wins ties); a detach applies only against the
// exact URL it detached from and only when strictly newer, so a late detach
// from an old relay can never clear a newer attachment elsewhere.
const APPLY_ATTACH_SQL = `
  update iroh_endpoint_bindings
  set relay_attached_url = $2,
      relay_attach_reported_at = $3::timestamptz
  where endpoint_id = $1
    and revoked_at is null
    and (relay_attach_reported_at is null or relay_attach_reported_at <= $3::timestamptz)
  returning id
`;

const APPLY_DETACH_SQL = `
  update iroh_endpoint_bindings
  set relay_attached_url = null,
      relay_attach_reported_at = $3::timestamptz
  where endpoint_id = $1
    and revoked_at is null
    and relay_attached_url = $2
    and relay_attach_reported_at < $3::timestamptz
  returning id
`;

const REPORT_HOOK = "relay-report";

function reportClient() {
  return relayHookDbClient(REPORT_HOOK, {
    maxConnections: RELAY_REPORT_MAX_CONCURRENT,
    statementTimeoutMs: RELAY_REPORT_STATEMENT_TIMEOUT_MS,
    settleMs: RELAY_REPORT_SETTLE_MS,
  });
}

function savedCustomRelayURLs(customRelays: unknown): string[] {
  if (!Array.isArray(customRelays)) return [];
  const urls: string[] = [];
  for (const relay of customRelays) {
    if (relay !== null && typeof relay === "object" && !Array.isArray(relay)) {
      const url = (relay as Record<string, unknown>).url;
      if (typeof url === "string") urls.push(url);
    }
  }
  return urls;
}

/**
 * Applies one verified report to the registry. Both statements run on the
 * dedicated deadline-bounded report client under the concurrency cap.
 *
 * The catalog/saved-set trust rule gates only ATTACH, because only an attach
 * publishes a URL. A detach merely clears the stored attachment, so it is
 * matched against the STORED URL by hostname and needs no trust resolution:
 * a custom relay deleted from the account's preferences must still be able
 * to detach cleanly, or its stale attachment would resurface if the same
 * relay were ever saved again (a forged clear already requires the shared
 * secret and only degrades discovery to the client-published fallback).
 */
export async function applyRelayAttachReport(
  report: RelayAttachReport,
): Promise<RelayReportOutcome> {
  return await withRelayReportSlot(async () => {
    const client = reportClient();
    const context = (await client.query(REPORT_CONTEXT_SQL, [report.endpointId]))[0];
    if (!context) return "unknown_endpoint" as const;

    let url: string;
    if (report.event === "attach") {
      const publishable = publishableRelayURLForHostname(
        report.relayId,
        savedCustomRelayURLs(context.customRelays),
      );
      if (publishable === null) return "untrusted_relay" as const;
      url = publishable;
    } else {
      const attachedUrl = typeof context.attachedUrl === "string"
        ? context.attachedUrl
        : null;
      if (attachedUrl === null || urlHostname(attachedUrl) !== report.relayId) {
        // Nothing (or a different relay's route) is published; the detach is
        // stale relative to the applied event stream.
        return "superseded" as const;
      }
      // Clear exactly what was read; the WHERE below re-checks it so a
      // concurrent attach between the two statements survives.
      url = attachedUrl;
    }

    const applied = await client.query(
      report.event === "attach" ? APPLY_ATTACH_SQL : APPLY_DETACH_SQL,
      [report.endpointId, url, report.reportedAt.toISOString()],
    );
    // Zero rows: an equal-or-newer event already holds the slot, the detach
    // target URL no longer matches, or the binding was revoked between the
    // two statements. All are stale-report shapes, not failures.
    return applied.length > 0 ? ("applied" as const) : ("superseded" as const);
  });
}

export async function closeRelayReportClientForTests(): Promise<void> {
  await closeRelayHookDbClientForTests(REPORT_HOOK);
}
