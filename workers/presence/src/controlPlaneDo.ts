// AccountControlPlane Durable Object — one instance per verified Stack user
// (the worker derives the id from the VERIFIED user id, never client input).
//
// Thin adapter: all protocol logic lives in controlPlane.ts (bun-testable);
// this file binds it to workerd — WebSocket hibernation, DO storage, the DO
// alarm, and the local account broker.
//
// Authorization happens in the worker before anything reaches this object
// (same trust model as TeamPresence): the worker verifies the Stack bearer
// token and resolves the account. Control-plane sockets are intentionally
// long-lived; the DO uses ONLY the connecting client's own bearer token for
// upstream calls, stored per-socket and deleted on close.

import { DurableObject } from "cloudflare:workers";
import * as Effect from "effect/Effect";
import { bearerToken } from "./auth";
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
import { rateLimitedJson } from "./retryAfterResponse";
import {
  pruneExpiredAccountState,
  nextAccountRetentionAt,
} from "./accountSqliteStorage";
import { accountDrizzleDatabase } from "./accountDrizzleDatabase";
import { accountDrizzleMigrations } from "./accountDrizzleMigrations";
import { migrate } from "drizzle-orm/durable-sqlite/migrator";
import { LocalIrohBroker } from "./iroh/localBroker";
import { sha256 } from "./iroh/model";
import type { IrohBindingRequestProof } from "./iroh/crypto";

export interface ControlPlaneEnv extends SentryEnv {
  CMUX_IROH_LAN_DISCOVERY_SECRET_B64?: string;
  CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64?: string;
  CMUX_IROH_GRANT_SIGNING_KEY_P8?: string;
  CMUX_IROH_GRANT_SIGNING_KID?: string;
  CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON?: string;
  CMUX_IROH_MINT_URL?: string;
  CMUX_IROH_MINT_HMAC_SECRET_B64?: string;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
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
  private readonly sqlite = this.ctx.storage.sql;
  private readonly db = accountDrizzleDatabase(this.ctx.storage);
  private readonly localIroh = new LocalIrohBroker(this.ctx.storage, {
    lanDiscoverySecretBase64: this.env.CMUX_IROH_LAN_DISCOVERY_SECRET_B64 ?? "",
    accountSubjectSecretBase64: this.env.CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64,
    grantSigningPrivateKeyPem: this.env.CMUX_IROH_GRANT_SIGNING_KEY_P8,
    grantSigningKid: this.env.CMUX_IROH_GRANT_SIGNING_KID,
    relayMinterUrl: this.env.CMUX_IROH_MINT_URL,
    relayMinterHmacSecretBase64: this.env.CMUX_IROH_MINT_HMAC_SECRET_B64,
    grantVerificationKeys: this.env.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON
      ? JSON.parse(this.env.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON)
      : { version: 1, current_kid: "", keys: [] },
  });

  constructor(ctx: DurableObjectState, env: ControlPlaneEnv) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      const now = Date.now();
      migrate(this.db, { migrations: accountDrizzleMigrations });
      pruneExpiredAccountState(this.sqlite, now);
      await this.scheduleRetention(now);
    });
  }

  private readonly core = new ControlPlaneCore({
    // DurableObjectStorage's get/put/delete structurally cover CtlStorage;
    // single widening cast, same pattern as TeamPresence.syncStorage().
    storage: this.ctx.storage as unknown as CtlStorage,
    now: () => Date.now(),
    upstream: async () => {
      // The Durable Object has no Vercel or database proxy fallback. The
      // local SQLite broker owns the control path; this adapter remains only
      // for the legacy fact-stream core until its facts are fully local.
      return { status: 503, json: { error: "local_control_plane_not_ready" } };
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

  private async handleFetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path.startsWith("/api/devices/iroh") || path.startsWith("/api/relay") || path.startsWith("/api/connectivity/")) {
      return await this.handleLocalIroh(request, path);
    }
    // Device revocation, forwarded by the worker with rebuilt headers after
    // Stack bearer verification. This DO instance IS the verified account
    // scope; the strict-parsed body carries only {endpointId, revoked}.
    if (request.method === "POST"
      && new URL(request.url).pathname === "/v1/control/devices/revoke") {
      if (!request.headers.get("x-control-account-id")?.trim()) {
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
    const accountId = request.headers.get("x-control-account-id")?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    // The DO keeps the connection's own bearer for its upstream proxy calls.
    const bearer = bearerToken(request);
    if (!bearer) return json({ error: "unauthorized" }, 401);
    // The web API's native auth requires the refresh token BESIDE the bearer
    // (parseNativeStackTokens); without it every upstream proxy call 401s.
    const refresh = request.headers.get("x-stack-refresh-token")?.trim() || undefined;
    const namespace = request.headers.get("x-cmux-app-namespace")?.trim() || undefined;

    const connected = this.ctx.getWebSockets().filter((ws) => {
      const attachment = wrapSocket(ws).getAttachment();
      return attachment !== null;
    }).length;
    if (connected >= MAX_CONTROL_SUBSCRIBERS_PER_ACCOUNT) {
      return rateLimitedJson({ error: "too_many_subscribers" });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    // Hibernation API: the DO can be evicted while sockets stay connected.
    this.ctx.acceptWebSocket(server);
    await this.core.handleConnect(wrapSocket(server), {
      sessionId: crypto.randomUUID(),
      bearer,
      ...(refresh ? { refresh } : {}),
      ...(namespace ? { namespace } : {}),
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleLocalIroh(request: Request, path: string): Promise<Response> {
    const accountId = request.headers.get("x-control-account-id")?.trim();
    if (!accountId) return json({ error: "account_required" }, 403);
    const namespace = request.headers.get("x-cmux-app-namespace")?.trim() || "legacy";
    let body: unknown = undefined;
    let bodyBytes = new Uint8Array();
    if (request.method !== "GET") {
      try { bodyBytes = new Uint8Array(await request.arrayBuffer()); body = JSON.parse(new TextDecoder().decode(bodyBytes)); } catch { return json({ error: "invalid_request" }, 400); }
    }
    const proof = this.bindingProof(request, bodyBytes, path);
    if (proof instanceof Response) return proof;
    const operation = path.endsWith("/challenge") ? "challenge"
      : path.endsWith("/register") ? "register"
      : path.endsWith("/pair-grants") ? "pair_grant"
      : path.endsWith("/endpoint-attestations") ? "endpoint_attestation"
      : path === "/api/relay/token" ? "relay_token"
      : path === "/api/devices/iroh" && request.method === "GET" ? "discover"
      : path === "/api/devices/iroh" && request.method === "DELETE" ? "revoke"
      : null;
    if (operation === null) return json({ error: "not_implemented" }, 501);
    try {
      const result = operation === "challenge"
        ? await Effect.runPromise(this.localIroh.issueChallenge(accountId, body, Date.now(), namespace))
        : operation === "register"
          ? await Effect.runPromise(this.localIroh.register(accountId, body, Date.now(), namespace))
          : operation === "discover"
            ? await Effect.runPromise(this.localIroh.discover(accountId, namespace))
            : operation === "revoke"
              ? await Effect.runPromise(this.localIroh.revoke(accountId, body, Date.now(), namespace, proof ?? undefined))
              : operation === "pair_grant"
                ? await Effect.runPromise(this.localIroh.issuePairGrant(accountId, body, Date.now(), namespace, proof ?? undefined))
                : operation === "endpoint_attestation"
                  ? await Effect.runPromise(this.localIroh.issueEndpointAttestation(accountId, body, Date.now(), namespace, proof ?? undefined))
                  : await this.localIroh.issueRelayToken(accountId, body, Date.now(), namespace, proof ?? undefined);
      return json(result, operation === "discover" || operation === "revoke" ? 200 : 201);
    } catch (error) {
      console.error("local iroh operation failed", String(error));
      const code = error && typeof error === "object" && "code" in error ? String((error as { code: unknown }).code) : "iroh_internal_error";
      const status = code.includes("not_found") ? 404 : code.includes("invalid") || code.includes("expired") ? 400 : 500;
      return json({ error: code }, status);
    }
  }

  private bindingProof(request: Request, body: Uint8Array, path: string): IrohBindingRequestProof | Response | null {
    const bindingId = request.headers.get("x-cmux-iroh-binding-id");
    const timestamp = request.headers.get("x-cmux-iroh-request-time");
    const signature = request.headers.get("x-cmux-iroh-request-signature");
    if (!bindingId && !timestamp && !signature) return null;
    if (!bindingId || !timestamp || !signature || !/^[0-9]+$/.test(timestamp)) return json({ error: "invalid_binding_request_proof" }, 400);
    return { bindingId, method: request.method, path, timestampSeconds: Number(timestamp), bodySha256: sha256(body), signature };
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
      pruneExpiredAccountState(this.sqlite, Date.now());
      await this.core.handleAlarm();
      await this.scheduleRetention(Date.now());
    } catch (error) {
      await captureSentryException(this.env, "cloudflare-control-plane", error, {
        durable_object: "AccountControlPlane",
        operation: "alarm",
      });
      throw error;
    }
  }

  private async scheduleRetention(now: number): Promise<void> {
    const deadline = nextAccountRetentionAt(this.sqlite, now);
    if (deadline !== null) await this.ensureAlarmAt(deadline);
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
