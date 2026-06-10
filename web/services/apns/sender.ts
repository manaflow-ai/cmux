// APNs token-based (JWT) sender over HTTP/2. No external deps: ES256 signing
// via node:crypto, transport via node:http2. Must run on the Node runtime
// (not edge). Pure helpers live in ./payload; this module owns crypto + I/O.

import crypto from "node:crypto";
import http2 from "node:http2";
import {
  apnsHostForEnvironment,
  buildApnsPayload,
  shouldPruneToken,
  type ApnsNotificationInput,
} from "./payload";

export interface ApnsConfig {
  /** Contents of the APNs Auth Key .p8 (PEM). Literal "\n" escapes allowed. */
  readonly keyP8: string;
  readonly keyId: string;
  readonly teamId: string;
}

export interface ApnsTarget {
  readonly deviceToken: string;
  readonly bundleId: string;
  readonly environment: string; // "sandbox" | "production"
}

export interface ApnsSendResult {
  readonly deviceToken: string;
  readonly status: number; // 0 = transport error / timeout
  readonly reason?: string;
  readonly prune: boolean;
}

interface ApnsHttp2Session {
  request(headers: http2.OutgoingHttpHeaders): http2.ClientHttp2Stream;
  close(): void;
  once(event: "error", listener: () => void): this;
}

interface ApnsTransport {
  connect(host: string): ApnsHttp2Session;
}

const nodeApnsTransport: ApnsTransport = {
  connect: (host) => http2.connect(`https://${host}`),
};

/** Normalize a .p8 that was stored with literal `\n` (common in env vars). */
export function normalizeP8(keyP8: string): string {
  return keyP8.includes("\\n") ? keyP8.replace(/\\n/g, "\n") : keyP8;
}

function base64url(input: Buffer | string): string {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/**
 * Sign an APNs provider-authentication JWT (ES256). `nowSeconds` is injected so
 * the signer is deterministic and unit-testable.
 */
export function signApnsJwt(config: ApnsConfig, nowSeconds: number): string {
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: nowSeconds }));
  const signingInput = `${header}.${claims}`;
  const key = crypto.createPrivateKey(normalizeP8(config.keyP8));
  // APNs (JOSE) requires the raw r||s signature, not DER.
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

// APNs allows reusing a provider token for up to 1h; refresh well before that.
const JWT_TTL_SECONDS = 50 * 60;
let cachedJwt: { token: string; issuedAt: number; keyId: string } | null = null;

function providerToken(config: ApnsConfig): string {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.keyId === config.keyId && now - cachedJwt.issuedAt < JWT_TTL_SECONDS) {
    return cachedJwt.token;
  }
  const token = signApnsJwt(config, now);
  cachedJwt = { token, issuedAt: now, keyId: config.keyId };
  return token;
}

/**
 * Send one payload to every target (grouped by APNs host so each host reuses a
 * single HTTP/2 connection). Returns a per-token result; callers prune tokens
 * whose `prune` is true.
 */
export async function sendApnsNotification(
  config: ApnsConfig,
  targets: readonly ApnsTarget[],
  input: ApnsNotificationInput,
  timeoutMs = 8000,
  transport: ApnsTransport = nodeApnsTransport,
): Promise<ApnsSendResult[]> {
  if (targets.length === 0) return [];
  const jwt = providerToken(config);
  const body = Buffer.from(JSON.stringify(buildApnsPayload(input)));
  // The delivered banner's identifier (the lever for Mac→iOS dismiss) IS the
  // apns-collapse-id when set. APNs caps it at 64 bytes; a UUID is 36, but guard
  // anyway so an over-long id degrades to "no collapse" instead of a 400.
  // Never set on a dismiss push: a collapse would try to REPLACE the delivered
  // banner with the invisible dismiss payload instead of leaving removal to the
  // app's background handler.
  const collapseId = input.kind === "dismiss" ? undefined : collapseIdFor(input.notificationId);
  // A dismiss push carries badge + content-available but nothing visible:
  // priority 5 (power-friendly, may coalesce) instead of the default 10, which
  // Apple reserves for pushes that present UI immediately. Still push-type
  // `alert` because a badge update is user-facing in Apple's taxonomy and a
  // `background`-type push may not carry `badge`.
  const priority = input.kind === "dismiss" ? "5" : undefined;

  const byHost = new Map<string, ApnsTarget[]>();
  for (const t of targets) {
    const host = apnsHostForEnvironment(t.environment);
    (byHost.get(host) ?? byHost.set(host, []).get(host)!).push(t);
  }

  const results = await Promise.all(
    [...byHost.entries()].map(([host, hostTargets]) =>
      sendHostGroup(transport, host, hostTargets, jwt, body, timeoutMs, collapseId, priority).catch(() =>
        connectionErrorResults(hostTargets),
      ),
    ),
  );
  return results.flat();
}

/** A valid (≤64-byte) apns-collapse-id for the notification id, or undefined. */
function collapseIdFor(notificationId: string | null | undefined): string | undefined {
  const id = notificationId?.trim();
  if (!id) return undefined;
  return Buffer.byteLength(id, "utf8") <= 64 ? id : undefined;
}

function connectionErrorResults(hostTargets: readonly ApnsTarget[]): ApnsSendResult[] {
  return hostTargets.map((target) => ({
    deviceToken: target.deviceToken,
    status: 0,
    reason: "connection_error",
    prune: false,
  }));
}

async function sendHostGroup(
  transport: ApnsTransport,
  host: string,
  hostTargets: readonly ApnsTarget[],
  jwt: string,
  body: Buffer,
  timeoutMs: number,
  collapseId: string | undefined,
  priority: string | undefined,
): Promise<ApnsSendResult[]> {
  let client: ApnsHttp2Session | null = null;
  try {
    const connectedClient = transport.connect(host);
    client = connectedClient;
    // A connection-level error fails every in-flight request for this host.
    const connError: Promise<null> = new Promise((resolve) => {
      connectedClient.once("error", () => resolve(null));
    });
    return await Promise.all(
      hostTargets.map((t) => sendOne(connectedClient, jwt, t, body, timeoutMs, connError, collapseId, priority)),
    );
  } catch {
    return connectionErrorResults(hostTargets);
  } finally {
    client?.close();
  }
}

function sendOne(
  client: ApnsHttp2Session,
  jwt: string,
  target: ApnsTarget,
  body: Buffer,
  timeoutMs: number,
  connError: Promise<null>,
  collapseId: string | undefined,
  priority: string | undefined,
): Promise<ApnsSendResult> {
  return new Promise<ApnsSendResult>((resolve) => {
    let settled = false;
    const finish = (status: number, reason?: string) => {
      if (settled) return;
      settled = true;
      resolve({ deviceToken: target.deviceToken, status, reason, prune: shouldPruneToken(status, reason) });
    };
    void connError.then(() => finish(0, "connection_error"));

    let req: http2.ClientHttp2Stream;
    try {
      const headers: http2.OutgoingHttpHeaders = {
        ":method": "POST",
        ":path": `/3/device/${target.deviceToken}`,
        "apns-topic": target.bundleId,
        "apns-push-type": "alert",
        authorization: `bearer ${jwt}`,
        "content-type": "application/json",
        "content-length": String(body.length),
      };
      // Sets the delivered notification's identifier on iOS, so a later
      // notification.dismissed event can clear this exact banner. Also collapses
      // repeated updates for the same notification into one.
      if (collapseId) headers["apns-collapse-id"] = collapseId;
      if (priority) headers["apns-priority"] = priority;
      req = client.request(headers);
    } catch (err) {
      finish(0, err instanceof Error ? err.message : "request_error");
      return;
    }
    req.setTimeout(timeoutMs, () => {
      req.close();
      finish(0, "timeout");
    });

    let status = 0;
    let data = "";
    req.on("response", (headers) => {
      status = Number(headers[":status"]) || 0;
    });
    req.on("data", (chunk) => {
      data += chunk;
    });
    req.on("end", () => {
      let reason: string | undefined;
      if (data) {
        try {
          reason = (JSON.parse(data) as { reason?: string }).reason;
        } catch {
          // non-JSON body (success has empty body); leave reason undefined
        }
      }
      finish(status, reason);
    });
    req.on("error", (err) => finish(0, err instanceof Error ? err.message : "request_error"));
    req.end(body);
  });
}
