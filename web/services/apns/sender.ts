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
): Promise<ApnsSendResult[]> {
  if (targets.length === 0) return [];
  const jwt = providerToken(config);
  const body = Buffer.from(JSON.stringify(buildApnsPayload(input)));

  const byHost = new Map<string, ApnsTarget[]>();
  for (const t of targets) {
    const host = apnsHostForEnvironment(t.environment);
    (byHost.get(host) ?? byHost.set(host, []).get(host)!).push(t);
  }

  const results: ApnsSendResult[] = [];
  for (const [host, hostTargets] of byHost) {
    const client = http2.connect(`https://${host}`);
    // A connection-level error fails every in-flight request for this host.
    const connError: Promise<null> = new Promise((resolve) => {
      client.once("error", () => resolve(null));
    });
    try {
      const hostResults = await Promise.all(
        hostTargets.map((t) => sendOne(client, jwt, t, body, timeoutMs, connError)),
      );
      results.push(...hostResults);
    } finally {
      client.close();
    }
  }
  return results;
}

function sendOne(
  client: http2.ClientHttp2Session,
  jwt: string,
  target: ApnsTarget,
  body: Buffer,
  timeoutMs: number,
  connError: Promise<null>,
): Promise<ApnsSendResult> {
  return new Promise<ApnsSendResult>((resolve) => {
    let settled = false;
    const finish = (status: number, reason?: string) => {
      if (settled) return;
      settled = true;
      resolve({ deviceToken: target.deviceToken, status, reason, prune: shouldPruneToken(status, reason) });
    };
    void connError.then(() => finish(0, "connection_error"));

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${target.deviceToken}`,
      "apns-topic": target.bundleId,
      "apns-push-type": "alert",
      authorization: `bearer ${jwt}`,
      "content-type": "application/json",
      "content-length": String(body.length),
    });
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
