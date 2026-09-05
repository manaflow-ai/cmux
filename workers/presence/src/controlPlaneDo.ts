// AccountControlPlane Durable Object — one instance per verified Stack user
// (the worker derives the id from the VERIFIED user id, never client input).
//
// Thin adapter: all protocol logic lives in controlPlane.ts (bun-testable);
// this file binds it to workerd — WebSocket hibernation, DO storage, the DO
// alarm, and the account-scoped Iroh HTTP backend.
//
// Authorization happens in the worker before anything reaches this object
// (same trust model as TeamPresence): the worker verifies the Stack bearer
// token and resolves the account. Control-plane sockets are intentionally
// long-lived; the DO uses ONLY the connecting client's own bearer token for
// upstream calls, stored per-socket and deleted on close.

import { DurableObject } from "cloudflare:workers";
import { bearerToken } from "./auth";
import {
  handleIrohControlRequest,
  type IrohHttpResult,
} from "./irohHttp";
import {
  makeWorkerIrohBackend,
  type IrohWorkerEnvironment,
  type WorkerIrohBackend,
} from "./irohBackend";
import type { TeamPresence } from "./do";
import {
  IROH_SESSION_RENEW_AFTER_SECONDS,
  IROH_SESSION_TICKET_HEADER,
  IROH_SESSION_TICKET_TTL_SECONDS,
  mintIrohSessionTicket,
  parseIrohSessionClientContext,
  sessionClientContextFromClaims,
  sessionClientNamespaceMatches,
  sessionTicketFromRequest,
  verifyIrohSessionTicket,
  type IrohSessionClaims,
  type IrohSessionVerification,
} from "./irohSession";
import {
  CONTROL_REFRESH_INTERVAL_MS,
  ControlPlaneCore,
  MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT,
  parseRevocationRequest,
  type CtlAttachment,
  type CtlSocket,
  type CtlStorage,
} from "./controlPlane";
import { captureSentryException, type SentryEnv } from "./sentry";
import {
  compatibilityProtectionHeaders,
  validatedCompatibilityBaseURL,
} from "./compatibility";

export interface ControlPlaneEnv extends SentryEnv, IrohWorkerEnvironment {
  /** Compatibility origin used only while CMUX_IROH_BACKEND_MODE is
   * "compatibility". Direct mode never sends Iroh control traffic to this
   * origin. */
  CMUX_WEB_BASE_URL?: string;
  /** "direct" terminates Iroh HTTP in this DO; "compatibility" forwards to
   * the legacy web route during a staged rollout. If omitted, the presence of
   * a Hyperdrive binding selects direct mode. */
  CMUX_IROH_BACKEND_MODE?: "direct" | "compatibility" | string;
  /** The account's connectivity DO namespace, used for an in-process route
   * revision nudge after a direct registration or revocation. */
  TEAM_PRESENCE?: DurableObjectNamespace<TeamPresence>;
  /** HMAC key shared with the web compatibility adapter. The key is also used
   * by the account DO to verify tickets after hibernation. */
  IROH_SESSION_SIGNING_KEY?: string;
  /** Staging-only Vercel deployment-protection bypass for the compatibility
   * lane. Never set this in direct/production mode. */
  VERCEL_PROTECTION_BYPASS_SECRET?: string;
}

const PRODUCTION_WEB_BASE_URL = "https://cmux.com";
const ACCOUNT_ID_HEADER = "x-control-account-id";
const REQUEST_ID_HEADER = "x-cmux-request-id";
const SESSION_OPEN_PATH = "/_internal/iroh/session/open";
const SESSION_RENEW_PATH = "/_internal/iroh/session/renew";
const SESSION_REVOKE_ALL_PATH = "/_internal/iroh/session/revoke-all";
const SESSION_ACCOUNT_KEY = "iroh:session:account";
const SESSION_EPOCH_KEY = "iroh:session:epoch";
const SESSION_PREFIX = "iroh:session:";
const MAX_STORED_IROH_SESSIONS = 32;
const SESSION_CLEANUP_SCAN_LIMIT = 64;
const SESSION_LAST_SEEN_WRITE_INTERVAL_MS = 60_000;
const MAX_SESSION_BODY_BYTES = 8 * 1_024;
const MAX_IROH_PROXY_BODY_BYTES = 64 * 1_024;

/** The only web paths this account object may proxy. Keeping this allowlist
 * tight prevents a ticket from becoming a generic SSRF capability. */
const IROH_PROXY_PATHS = new Map<string, ReadonlySet<string>>([
  ["/api/devices/iroh", new Set(["GET", "DELETE"])],
  ["/api/devices/iroh/challenge", new Set(["POST"])],
  ["/api/devices/iroh/register", new Set(["POST"])],
  ["/api/devices/iroh/pair-grants", new Set(["POST"])],
  ["/api/devices/iroh/endpoint-attestations", new Set(["POST"])],
  ["/api/devices/iroh/relay-token", new Set(["POST"])],
  ["/api/relay/token", new Set(["POST"])],
  ["/api/relay/preferences", new Set(["GET", "PUT"])],
  ["/api/connectivity/v2/sync", new Set(["POST"])],
  ["/api/connectivity/v3/sync", new Set(["POST"])],
]);

interface StoredIrohSession {
  accountId: string;
  expiresAt: number;
  epoch: number;
  createdAt: number;
  lastSeenAt: number;
}

function isStoredIrohSession(value: unknown): value is StoredIrohSession {
  if (!isObject(value)) return false;
  return typeof value.accountId === "string"
    && Number.isFinite(value.expiresAt)
    && Number.isFinite(value.epoch)
    && Number.isFinite(value.createdAt)
    && Number.isFinite(value.lastSeenAt);
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function sessionVerificationError(
  error: Extract<IrohSessionVerification, { readonly ok: false }>["error"],
): Response {
  return error === "not_configured"
    ? json({ error: "session_unavailable" }, 503)
    : json({ error: `session_${error}` }, 401);
}

function requestID(request: Request): string {
  const supplied = request.headers.get(REQUEST_ID_HEADER)?.trim();
  return supplied && /^[A-Za-z0-9._:-]{1,128}$/.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function boundedJson(request: Request, maxBytes: number): Promise<unknown | null> {
  const length = request.headers.get("content-length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > maxBytes)) return null;
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.byteLength > maxBytes) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

/** Wrap a hibernatable WebSocket as the core's transport-neutral socket. The
 * attachment rides serializeAttachment so it survives DO hibernation. */
function wrapSocket(ws: WebSocket): CtlSocket {
  return {
    send(data: string): void {
      ws.send(data);
    },
    close(code?: number, reason?: string): void {
      ws.close(code, reason);
    },
    getAttachment(): CtlAttachment | null {
      try {
        const attachment = ws.deserializeAttachment() as CtlAttachment | null;
        return attachment && typeof attachment.sessionId === "string"
          && (attachment.expiresAt === undefined || typeof attachment.expiresAt === "number")
          ? attachment
          : null;
      } catch {
        return null;
      }
    },
    setAttachment(attachment: CtlAttachment): void {
      try {
        ws.serializeAttachment(attachment);
      } catch {
        // attachment write failed; the socket is likely gone
      }
    },
  };
}

export class AccountControlPlane extends DurableObject<ControlPlaneEnv> {
  private irohBackend: WorkerIrohBackend | undefined;

  private directIrohBackendEnabled(): boolean {
    // The deployment mode is an explicit safety switch. A binding alone must
    // not silently move a rollout from the compatibility proxy to Aurora.
    return this.env.CMUX_IROH_BACKEND_MODE === "direct"
      || (this.env.CMUX_IROH_BACKEND_MODE === undefined
        && this.env.HYPERDRIVE !== undefined);
  }

  private readonly core = new ControlPlaneCore({
    // DurableObjectStorage's get/put/delete structurally cover CtlStorage;
    // single widening cast, same pattern as TeamPresence.syncStorage().
    storage: this.ctx.storage as unknown as CtlStorage,
    now: () => Date.now(),
    upstream: async (path, init) => {
      if (this.directIrohBackendEnabled()) {
        const accountId = await this.ctx.storage.get<string>(SESSION_ACCOUNT_KEY);
        if (!accountId) throw new Error("iroh account is not initialized");
        const directRequest = new Request(`https://cmux.internal${path}`, {
          method: init.method,
          headers: init.headers,
          ...(init.body !== undefined ? { body: init.body } : {}),
        });
        const started = Date.now();
        const result = await handleIrohControlRequest(
          directRequest,
          accountId,
          this.irohBackend ??= makeWorkerIrohBackend(this.env),
          { accountSessionTrusted: true },
        );
        if (result.revision !== undefined) {
          this.ctx.waitUntil(this.publishConnectivityRevision(
            accountId,
            result.revision,
          ).catch(async (error) => {
            console.warn("iroh socket connectivity invalidation failed", {
              request_id: init.headers[REQUEST_ID_HEADER] ?? "-",
              operation: path,
            });
            await captureSentryException(this.env, "cloudflare-iroh-control", error, {
              durable_object: "AccountControlPlane",
              operation: "connectivity_invalidation",
              path,
              request_id: init.headers[REQUEST_ID_HEADER] ?? "-",
            });
          }));
        }
        const jsonBody = await result.response.json().catch(() => null);
        console.log("iroh control socket request", {
          request_id: init.headers[REQUEST_ID_HEADER] ?? "-",
          operation: path,
          status: result.response.status,
          latency_ms: Date.now() - started,
          backend: "direct",
        });
        return { status: result.response.status, json: jsonBody };
      }

      const base = validatedCompatibilityBaseURL(
        this.env.CMUX_WEB_BASE_URL ?? PRODUCTION_WEB_BASE_URL,
      );
      if (!base) {
        throw new Error("compatibility_origin_not_https");
      }
      let response: Response;
      try {
        response = await fetch(`${base}${path}`, {
          method: init.method,
          headers: init.headers,
          ...(init.body !== undefined ? { body: init.body } : {}),
        });
      } catch (error) {
        // Preserve connection-level failures for the core's one immediate
        // retry, while leaving a safe, token-free breadcrumb in the DO tail.
        console.error(
          `control-plane upstream ${init.method} ${path} network failure`,
          String(error).slice(0, 300),
        );
        await captureSentryException(this.env, "cloudflare-control-plane", error, {
          durable_object: "AccountControlPlane",
          operation: "upstream_fetch",
          method: init.method,
          path,
          failure: "network",
        });
        throw error;
      }
      // A connection-level failure throws out of fetch (the core's retry-once
      // trigger); any HTTP response resolves and is never retried.
      const json = await response.json().catch(() => null);
      if (response.status >= 400) {
        // Upstream refusals must be attributable from the worker tail alone;
        // clients only ever see the mapped retryable/non-retryable error code.
        console.error(
          `control-plane upstream ${init.method} ${path} -> ${response.status}`,
          JSON.stringify(json)?.slice(0, 300) ?? "<no body>",
        );
        await captureSentryException(this.env, "cloudflare-control-plane", new Error(
          `upstream ${init.method} ${path} returned ${response.status}`,
        ), {
          durable_object: "AccountControlPlane",
          operation: "upstream_fetch",
          method: init.method,
          path,
          status: response.status,
          failure: "http",
        });
      }
      return { status: response.status, json };
    },
    scheduleAlarmAt: (atMs) => this.ensureAlarmAt(atMs),
    sockets: () => this.ctx.getWebSockets().map(wrapSocket),
  });

  override async fetch(request: Request): Promise<Response> {
    try {
      return await this.handleFetch(request);
    } catch (error) {
      await captureSentryException(this.env, "cloudflare-control-plane", error, {
        durable_object: "AccountControlPlane",
        operation: "fetch",
        path: new URL(request.url).pathname,
        method: request.method,
      });
      throw error;
    }
  }

  /** Open a session inside the account object.  The Worker has already
   * verified the Stack bearer before forwarding this internal request.  The
   * object still owns the session record and epoch so every subsequent request
   * is checked by the same single-writer authority. */
  private async openIrohSession(request: Request): Promise<Response> {
    const accountId = request.headers.get(ACCOUNT_ID_HEADER)?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    const body = await boundedJson(request, MAX_SESSION_BODY_BYTES);
    if (!isObject(body)) return json({ error: "invalid_request" }, 400);
    const context = parseIrohSessionClientContext(body);
    if (context === null) return json({ error: "invalid_request" }, 400);
    const headerNamespace = request.headers.get("x-cmux-app-namespace")?.trim();
    if (!sessionClientNamespaceMatches(context, headerNamespace)) {
      return json({ error: "client_namespace_mismatch" }, 403);
    }
    const currentAccount = await this.ctx.storage.get<string>(SESSION_ACCOUNT_KEY);
    if (currentAccount !== undefined && currentAccount !== accountId) {
      // This should be unreachable because the Worker derives the object id
      // from the verified account. Keep the check in the object as a second
      // isolation fence in case a binding is misconfigured.
      return json({ error: "account_mismatch" }, 403);
    }
    if (currentAccount === undefined) {
      await this.ctx.storage.put(SESSION_ACCOUNT_KEY, accountId);
    }
    const now = Date.now();
    const epoch = (await this.ctx.storage.get<number>(SESSION_EPOCH_KEY)) ?? 0;
    const minted = await mintIrohSessionTicket(this.env.IROH_SESSION_SIGNING_KEY, {
      accountId,
      nowMs: now,
      epoch,
      ...(context ? context : {}),
    }).catch(() => null);
    if (!minted) return json({ error: "session_unavailable" }, 503);
    await this.ctx.storage.put(`${SESSION_PREFIX}${minted.claims.sid}`, {
      accountId,
      expiresAt: minted.claims.exp * 1_000,
      epoch,
      createdAt: now,
      lastSeenAt: now,
    } satisfies StoredIrohSession);
    await this.compactIrohSessions(now, epoch, minted.claims.sid);
    return json({
      ticket: minted.ticket,
      sessionId: minted.claims.sid,
      accountId,
      expiresAt: new Date(minted.claims.exp * 1_000).toISOString(),
      renewAfter: new Date(minted.claims.renewAt * 1_000).toISOString(),
    }, 201);
  }

  /** Keep renewal bounded. A phone can be suspended for months and then
   * reconnect repeatedly, so retaining every historical session id would
   * otherwise turn a harmless in-memory ticket cache into unbounded DO state.
   */
  private async compactIrohSessions(
    now: number,
    epoch: number,
    newestSessionID: string,
  ): Promise<void> {
    const rows = await this.ctx.storage.list<unknown>({
      prefix: SESSION_PREFIX,
      limit: SESSION_CLEANUP_SCAN_LIMIT,
    });
    const active: Array<{ key: string; value: StoredIrohSession }> = [];
    const deletes: string[] = [];
    for (const [key, value] of rows) {
      if (!key.startsWith(SESSION_PREFIX) || !isStoredIrohSession(value)) continue;
      if (value.expiresAt <= now || value.epoch !== epoch) {
        deletes.push(key);
      } else {
        active.push({ key, value });
      }
    }
    active.sort((left, right) =>
      right.value.lastSeenAt - left.value.lastSeenAt
      || right.value.createdAt - left.value.createdAt,
    );
    for (const row of active.slice(MAX_STORED_IROH_SESSIONS)) {
      if (row.key !== `${SESSION_PREFIX}${newestSessionID}`) deletes.push(row.key);
    }
    if (deletes.length === 0) return;
    await this.ctx.storage.delete(deletes);
  }

  /** Renewing is deliberately a new session id.  An in-flight request using
   * the old ticket remains valid until its original expiry, while future
   * requests can be fenced by the account epoch if the account is revoked. */
  private async renewIrohSession(request: Request): Promise<Response> {
    const accountId = request.headers.get(ACCOUNT_ID_HEADER)?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    const verified = await this.authenticateIrohTicket(request, accountId);
    if (!verified.ok) return verified.response;
    const context = sessionClientContextFromClaims(verified.claims);
    if (context === null) return json({ error: "session_invalid" }, 401);
    return this.openIrohSession(new Request(request.url, {
      method: "POST",
      headers: new Headers([
        [ACCOUNT_ID_HEADER, accountId],
        ...(context ? [["x-cmux-app-namespace", context.clientNamespace] as const] : []),
      ]),
      // An account-only ticket renews with an empty, exact session context.
      // `{renew: true}` used to be silently ignored by the context parser and
      // made the internal request shape less strict than the public bootstrap.
      body: JSON.stringify(context ?? {}),
    }));
  }

  private async revokeAllIrohSessions(request: Request): Promise<Response> {
    const accountId = request.headers.get(ACCOUNT_ID_HEADER)?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    const currentAccount = await this.ctx.storage.get<string>(SESSION_ACCOUNT_KEY);
    if (currentAccount !== undefined && currentAccount !== accountId) {
      return json({ error: "account_mismatch" }, 403);
    }
    const epoch = ((await this.ctx.storage.get<number>(SESSION_EPOCH_KEY)) ?? 0) + 1;
    await this.ctx.storage.put(SESSION_EPOCH_KEY, epoch);
    // Close ticket-authenticated control sockets immediately. Legacy sockets
    // are left alone because they have their own Stack-token expiry fence.
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = wrapSocket(ws).getAttachment();
      if (!attachment?.sessionId) continue;
      try { ws.close(1008, "session revoked"); } catch { /* already closed */ }
    }
    return json({ ok: true, epoch }, 200);
  }

  private async authenticateIrohTicket(
    request: Request,
    expectedAccountId?: string,
  ): Promise<{ ok: true; claims: IrohSessionClaims } | { ok: false; response: Response }> {
    const ticket = sessionTicketFromRequest(request);
    if (!ticket) return { ok: false, response: json({ error: "session_required" }, 401) };
    const now = Date.now();
    const verification = await verifyIrohSessionTicket(
      this.env.IROH_SESSION_SIGNING_KEY,
      ticket,
      now,
    );
    if (!verification.ok) {
      return { ok: false, response: sessionVerificationError(verification.error) };
    }
    const accountId = expectedAccountId ?? request.headers.get(ACCOUNT_ID_HEADER)?.trim();
    if (!accountId || accountId !== verification.claims.accountId) {
      return { ok: false, response: json({ error: "account_mismatch" }, 403) };
    }
    const namespace = request.headers.get("x-cmux-app-namespace")?.trim() || "legacy";
    const context = sessionClientContextFromClaims(verification.claims);
    if (!sessionClientNamespaceMatches(context, namespace)) {
      return { ok: false, response: json({ error: "client_namespace_mismatch" }, 403) };
    }
    const currentAccount = await this.ctx.storage.get<string>(SESSION_ACCOUNT_KEY);
    if (currentAccount !== undefined && currentAccount !== accountId) {
      return { ok: false, response: json({ error: "account_mismatch" }, 403) };
    }
    const epoch = (await this.ctx.storage.get<number>(SESSION_EPOCH_KEY)) ?? 0;
    if (verification.claims.epoch !== epoch) {
      return { ok: false, response: json({ error: "session_revoked" }, 401) };
    }
    const stored = await this.ctx.storage.get<StoredIrohSession>(
      `${SESSION_PREFIX}${verification.claims.sid}`,
    );
    if (!stored || stored.accountId !== accountId || stored.epoch !== epoch
      || stored.expiresAt <= now) {
      return { ok: false, response: json({ error: "session_unknown" }, 401) };
    }
    // A coarse write interval preserves last-seen observability without turning
    // every ordinary request into a Durable Object storage mutation.
    if (now - stored.lastSeenAt >= SESSION_LAST_SEEN_WRITE_INTERVAL_MS) {
      await this.ctx.storage.put(`${SESSION_PREFIX}${verification.claims.sid}`, {
        ...stored,
        lastSeenAt: now,
      } satisfies StoredIrohSession);
    }
    return { ok: true, claims: verification.claims };
  }

  private async proxyIrohRequest(
    request: Request,
    claims: IrohSessionClaims,
  ): Promise<Response> {
    const url = new URL(request.url);
    const methods = IROH_PROXY_PATHS.get(url.pathname);
    if (!methods || !methods.has(request.method)) return json({ error: "not_found" }, 404);

    // In direct mode the account object is the terminal HTTP authority. The
    // request body is parsed once by the adapter and the repositories use the
    // existing Aurora/Postgres schema through Hyperdrive. No Vercel fetch or
    // Stack Auth call is made on this path.
    const direct = this.directIrohBackendEnabled();
    if (direct) {
      const id = requestID(request);
      const started = Date.now();
      let result: IrohHttpResult;
      try {
        result = await handleIrohControlRequest(
          request,
          claims.accountId,
          this.irohBackend ??= makeWorkerIrohBackend(this.env),
          { accountSessionTrusted: true },
        );
      } catch (error) {
        console.error("iroh direct backend unavailable", {
          request_id: id,
          operation: url.pathname,
          failure: "backend_initialization",
        });
        await captureSentryException(this.env, "cloudflare-iroh-control", error, {
          durable_object: "AccountControlPlane",
          operation: "iroh_direct_backend",
          path: url.pathname,
          request_id: id,
        });
        return json({ error: "iroh_backend_unavailable", requestId: id }, 503);
      }

      // Connectivity invalidation is an acceleration hint. It is deliberately
      // detached from the response so a slow or unavailable subscriber DO can
      // never add to the registration/mutation round trip.
      if (result.revision !== undefined) {
        this.ctx.waitUntil(this.publishConnectivityRevision(
          claims.accountId,
          result.revision,
        ).catch(async (error) => {
          console.warn("iroh connectivity invalidation failed", {
            request_id: id,
            operation: url.pathname,
          });
          await captureSentryException(this.env, "cloudflare-iroh-control", error, {
            durable_object: "AccountControlPlane",
            operation: "connectivity_invalidation",
            path: url.pathname,
            request_id: id,
          });
        }));
      }

      const headers = new Headers(result.response.headers);
      headers.set(REQUEST_ID_HEADER, id);
      const duration = Math.max(0, Date.now() - started);
      const existingTiming = headers.get("server-timing");
      headers.set(
        "server-timing",
        existingTiming ? `${existingTiming}, iroh-do;dur=${duration}` : `iroh-do;dur=${duration}`,
      );
      console.log("iroh direct request", {
        request_id: id,
        operation: url.pathname,
        status: result.response.status,
        latency_ms: duration,
        session: claims.sid.slice(0, 12),
      });
      return new Response(result.response.body, {
        status: result.response.status,
        headers,
      });
    }

    // Compatibility mode is retained for a staged deployment or a local
    // worker without a Hyperdrive binding. It is explicit and observable so a
    // production rollout cannot silently fall back to Vercel.
    const base = validatedCompatibilityBaseURL(
      this.env.CMUX_WEB_BASE_URL ?? PRODUCTION_WEB_BASE_URL,
    );
    if (!base) {
      const id = requestID(request);
      console.error("iroh control compatibility origin rejected", {
        request_id: id,
        operation: url.pathname,
        reason: "https_required",
      });
      return json({ error: "iroh_backend_unavailable", requestId: id }, 503);
    }
    const target = `${base}${url.pathname}${url.search}`;
    const headers = new Headers();
    for (const name of [
      "accept",
      "content-type",
      "x-cmux-app-namespace",
      "x-cmux-iroh-binding-id",
      "x-cmux-iroh-request-time",
      "x-cmux-iroh-request-signature",
      "x-cmux-client-scope",
      "x-cmux-discovery-scope",
    ]) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    headers.set(IROH_SESSION_TICKET_HEADER, sessionTicketFromRequest(request)!);
    for (const [name, value] of Object.entries(compatibilityProtectionHeaders(
      base,
      this.env.VERCEL_PROTECTION_BYPASS_SECRET,
    ))) {
      headers.set(name, value);
    }
    const id = requestID(request);
    headers.set(REQUEST_ID_HEADER, id);
    let body: ArrayBuffer | undefined;
    if (request.method !== "GET" && request.method !== "HEAD") {
      body = await request.arrayBuffer();
      if (body.byteLength > MAX_IROH_PROXY_BODY_BYTES) {
        return json({ error: "request_too_large" }, 413);
      }
    }
    const started = Date.now();
    let response: Response;
    try {
      response = await fetch(target, {
        method: request.method,
        headers,
        ...(body ? { body } : {}),
        // Keep redirects visible as an upstream response.  We reject them
        // below, but this preserves the status/location in observability
        // instead of turning deployment protection into an opaque TypeError.
        redirect: "manual",
        signal: AbortSignal.timeout(15_000),
      });
    } catch (error) {
      console.error("iroh control upstream network failure", {
        request_id: id,
        operation: url.pathname,
        failure: "network",
        error: String(error).slice(0, 240),
      });
      await captureSentryException(this.env, "cloudflare-iroh-control", error, {
        durable_object: "AccountControlPlane",
        operation: "iroh_proxy",
        path: url.pathname,
        request_id: id,
      });
      return json({ error: "iroh_backend_unavailable", requestId: id }, 503);
    }
    if (response.status >= 300 && response.status < 400) {
      console.error("iroh control upstream redirect rejected", {
        request_id: id,
        operation: url.pathname,
        status: response.status,
        location_host: response.headers.get("location")
          ? (() => {
            try { return new URL(response.headers.get("location")!).hostname; } catch { return "invalid"; }
          })()
          : "none",
        compatibility_bypass_configured: Boolean(
          this.env.VERCEL_PROTECTION_BYPASS_SECRET?.trim(),
        ),
      });
      return json({ error: "iroh_backend_unavailable", requestId: id }, 503);
    }
    const responseHeaders = new Headers();
    for (const name of ["content-type", "cache-control", "retry-after", "location"]) {
      const value = response.headers.get(name);
      if (value) responseHeaders.set(name, value);
    }
    responseHeaders.set(REQUEST_ID_HEADER, id);
    responseHeaders.set(
      "server-timing",
      `iroh-do;dur=${Math.max(0, Date.now() - started)}`,
    );
    console.log("iroh control request", {
      request_id: id,
      operation: url.pathname,
      status: response.status,
      latency_ms: Date.now() - started,
      session: claims.sid.slice(0, 12),
    });
    return new Response(response.body, {
      status: response.status,
      headers: responseHeaders,
    });
  }

  private async publishConnectivityRevision(
    accountId: string,
    revision: number,
  ): Promise<void> {
    const namespace = this.env.TEAM_PRESENCE;
    if (!namespace) return;
    const stub = namespace.get(
      namespace.idFromName(`connectivity:user:${accountId}`),
    );
    await stub.invalidateConnectivity(accountId, revision);
  }

  private async handleFetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (request.method === "POST" && path === SESSION_OPEN_PATH) {
      return this.openIrohSession(request);
    }
    if (request.method === "POST" && path === SESSION_RENEW_PATH) {
      return this.renewIrohSession(request);
    }
    if (request.method === "POST" && path === SESSION_REVOKE_ALL_PATH) {
      return this.revokeAllIrohSessions(request);
    }

    // HTTP Iroh control requests are routed through this same account object
    // as the long-lived control socket. The Worker has stripped client auth
    // headers and stamped the verified account id; the object verifies the
    // ticket again before touching the upstream or any state.
    if (IROH_PROXY_PATHS.has(path)) {
      const accountId = request.headers.get(ACCOUNT_ID_HEADER)?.trim();
      const verified = await this.authenticateIrohTicket(request, accountId);
      if (!verified.ok) return verified.response;
      return this.proxyIrohRequest(request, verified.claims);
    }

    // Device revocation, forwarded by the worker with rebuilt headers after
    // Stack bearer verification. This DO instance IS the verified account
    // scope; the strict-parsed body carries only {endpointId, revoked}.
    if (request.method === "POST"
      && new URL(request.url).pathname === "/v1/control/devices/revoke") {
      if (!request.headers.get(ACCOUNT_ID_HEADER)?.trim()) {
        return json({ error: "account_required" }, 403);
      }
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid_request" }, 400);
      }
      const parsed = parseRevocationRequest(body);
      if (parsed === null) return json({ error: "invalid_request" }, 400);
      const result = await this.core.handleRevocation(parsed);
      return json({ ok: true, ...result }, 200);
    }
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "websocket_required" }, 400);
    }
    // Verified by the worker; never client input.
    const accountId = request.headers.get(ACCOUNT_ID_HEADER)?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    // Legacy bearer sockets can arrive before the session bootstrap route was
    // introduced. Seed the same account owner marker used by direct HTTP
    // requests so their first discovery refresh has an explicit account scope;
    // never overwrite a marker belonging to another DO account.
    const currentAccount = await this.ctx.storage.get<string>(SESSION_ACCOUNT_KEY);
    if (currentAccount !== undefined && currentAccount !== accountId) {
      return json({ error: "account_mismatch" }, 403);
    }
    if (currentAccount === undefined) {
      await this.ctx.storage.put(SESSION_ACCOUNT_KEY, accountId);
    }
    const ticket = sessionTicketFromRequest(request);
    const verifiedTicket = ticket
      ? await this.authenticateIrohTicket(request, accountId)
      : null;
    if (ticket && (!verifiedTicket || !verifiedTicket.ok)) {
      return verifiedTicket?.response ?? json({ error: "unauthorized" }, 401);
    }
    // The DO keeps the connection's own bearer or session ticket for its
    // upstream proxy calls. New sockets use the ticket and never retain Stack
    // credentials; the bearer branch is kept for old clients during rollout.
    const bearer = bearerToken(request);
    if (!ticket && !bearer) return json({ error: "unauthorized" }, 401);
    // The web API's native auth requires the refresh token BESIDE the bearer
    // (parseNativeStackTokens); without it every upstream proxy call 401s.
    const refresh = request.headers.get("x-stack-refresh-token")?.trim() || undefined;
    // A legacy bearer socket has no signed client-context claim. Keep it in
    // the legacy projection instead of allowing an arbitrary namespace header
    // to become an implicit cross-app directory grant.
    const namespace = ticket
      ? request.headers.get("x-cmux-app-namespace")?.trim() || undefined
      : undefined;

    const connected = this.ctx.getWebSockets().filter((ws) => {
      const attachment = wrapSocket(ws).getAttachment();
      return attachment !== null;
    }).length;
    if (connected >= MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT) {
      return json({ error: "too_many_subscribers" }, 429);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Hibernation API: the DO can be evicted while sockets stay connected.
    this.ctx.acceptWebSocket(server);
    await this.core.handleConnect(wrapSocket(server), {
      sessionId: crypto.randomUUID(),
      ...(bearer ? { bearer } : {}),
      ...(ticket && verifiedTicket?.ok
        ? { sessionTicket: ticket, expiresAt: verifiedTicket.claims.exp * 1_000 }
        : {}),
      ...(!ticket && refresh ? { refresh } : {}),
      ...(namespace ? { namespace } : {}),
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      await this.core.handleMessage(wrapSocket(ws), message);
    } catch (error) {
      await captureSentryException(this.env, "cloudflare-control-plane", error, {
        durable_object: "AccountControlPlane",
        operation: "websocket_message",
      });
      throw error;
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    try {
      await this.core.handleClose(wrapSocket(ws));
    } catch (error) {
      await captureSentryException(this.env, "cloudflare-control-plane", error, {
        durable_object: "AccountControlPlane",
        operation: "websocket_close",
      });
      throw error;
    }
    try {
      ws.close();
    } catch {
      // already closed
    }
  }

  override async alarm(): Promise<void> {
    try {
      await this.core.handleAlarm();
    } catch (error) {
      await captureSentryException(this.env, "cloudflare-control-plane", error, {
        durable_object: "AccountControlPlane",
        operation: "alarm",
      });
      throw error;
    }
  }

  /** Pull the alarm earlier if `due` precedes the currently scheduled one
   * (same ensure-at semantics as TeamPresence). The alarm handler reschedules
   * the steady CONTROL_REFRESH_INTERVAL_MS cadence itself while sockets are
   * connected, so this only ever needs the cheap min(). */
  private async ensureAlarmAt(due: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > due) {
      await this.ctx.storage.setAlarm(due);
    }
  }
}

/** Re-exported so wrangler migrations and the worker Env can reference one
 * canonical cadence constant from the adapter module. */
export { CONTROL_REFRESH_INTERVAL_MS };
