import { base64Decode, base64url } from "./crypto";
import { csv, type Env } from "./env";

// APNs for Computer Use approval questions (PROTOCOL.md, Computer Use
// approvals, Phone push). Secrets: APNS_KEY_P8 (PKCS#8 PEM), APNS_KEY_ID,
// APNS_TEAM_ID; APNS_TOPICS lists the bundle ids a phone may register. Without
// them the hub sends no push and phones hear questions only on their socket.

export interface ApnsConfig {
  keyP8: string;
  keyId: string;
  teamId: string;
}

export function apnsConfig(env: Env): ApnsConfig | null {
  return env.APNS_KEY_P8 && env.APNS_KEY_ID && env.APNS_TEAM_ID ? { keyP8: env.APNS_KEY_P8, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID } : null;
}

export function apnsTopics(env: Env): Set<string> {
  return new Set(csv(env.APNS_TOPICS));
}

export type ApnsEnvironment = "production" | "development";

export function apnsHost(environment: ApnsEnvironment): string {
  return environment === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
}

/** Apple wants one provider token reused for 20 to 60 minutes: one per isolate, renewed after 50. */
let cached: { id: string; token: string; at: number } | null = null;

function pemBody(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  return base64Decode(body);
}

export async function providerToken(config: ApnsConfig, now: number): Promise<string> {
  const id = `${config.teamId}:${config.keyId}:${config.keyP8.length}:${config.keyP8.slice(-16)}`;
  if (cached && cached.id === id && now - cached.at < 50 * 60_000) return cached.token;
  const key = await crypto.subtle.importKey("pkcs8", pemBody(config.keyP8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const enc = new TextEncoder();
  const header = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid: config.keyId })));
  const claims = base64url(enc.encode(JSON.stringify({ iss: config.teamId, iat: Math.floor(now / 1000) })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${header}.${claims}`));
  const token = `${header}.${claims}.${base64url(new Uint8Array(sig))}`;
  cached = { id, token, at: now };
  return token;
}

export interface ApnsTarget {
  token: string;
  topic: string;
  environment: ApnsEnvironment;
}

export interface ApnsAlert {
  payload: unknown;
  collapseId: string;
  /** Unix seconds after which APNs drops the push. */
  expiration: number;
}

/** What APNs said: `gone` means the token is dead (410, BadDeviceToken) and should be forgotten. */
export type ApnsOutcome = "sent" | "gone" | "failed";

export async function sendAlert(config: ApnsConfig, target: ApnsTarget, alert: ApnsAlert, now: number): Promise<ApnsOutcome> {
  try {
    const res = await fetch(`${apnsHost(target.environment)}/3/device/${target.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(config, now)}`,
        "apns-topic": target.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": alert.collapseId,
        "apns-expiration": String(alert.expiration),
        "content-type": "application/json",
      },
      body: JSON.stringify(alert.payload),
    });
    if (res.ok) return "sent";
    let reason = "";
    try {
      reason = ((await res.json()) as { reason?: string }).reason ?? "";
    } catch {
      reason = "";
    }
    // A refused provider token is made again on the next push instead of failing for 50 minutes.
    if (res.status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) cached = null;
    if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic") return "gone";
    console.error("apns push failed", res.status, reason);
    return "failed";
  } catch (err) {
    console.error("apns push failed", err instanceof Error ? err.message : String(err));
    return "failed";
  }
}
