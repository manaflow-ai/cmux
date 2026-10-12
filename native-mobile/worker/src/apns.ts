// APNs: provider-token (JWT, ES256) auth and payload builders.
// Pure functions except `sendApns`; unit tests in test/apns.test.mjs.

export type ApnsEnvironment = "production" | "sandbox";

export interface ApnsKey {
  /// PKCS#8 PEM of the APNs auth key (.p8).
  p8: string;
  keyId: string;
  teamId: string;
}

export type FeedKind = "question" | "permission" | "done" | "error" | "notice";
export const FEED_KINDS: readonly FeedKind[] = ["question", "permission", "done", "error", "notice"];

export interface FeedOption {
  key: string;
  label: string;
}

/// An attention event as the host posts it (`POST /v1/hosts/:id/events`).
export interface AttentionEvent {
  id: string;
  kind: FeedKind;
  title: string;
  body: string;
  surface: number | null;
  workspace: string | null;
  agent: string | null;
  options: FeedOption[];
  quote: string | null;
  created_at: number;
}

export type ActivityState = "working" | "needs_input" | "done";

/// Live Activity content state. Field names match the Swift
/// `AgentActivityAttributes.ContentState` (default Codable keys).
export interface ActivityContentState {
  state: ActivityState;
  /// Unix seconds; the widget renders elapsed time from it.
  startedAt: number;
  detail: string;
}

/// Static Live Activity attributes (`AgentActivityAttributes`).
export interface ActivityAttributes {
  hostID: string;
  surface: number;
  agent: string;
  workspace: string;
}

export const CATEGORY: Record<FeedKind, string> = {
  question: "FEED_QUESTION",
  permission: "FEED_PERMISSION",
  done: "FEED_DONE",
  error: "FEED_GENERIC",
  notice: "FEED_GENERIC",
};

const MAX_PAYLOAD_BYTES = 4096;

// ---------- JWT ----------

export function b64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let bin = "";
  for (const b of data) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, "")
    .replace(/-----END [A-Z ]+-----/g, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function importApnsKey(p8: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("pkcs8", pemToDer(p8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/// ES256 provider token. WebCrypto returns the raw r||s signature JWS wants.
export async function signApnsJwt(key: ApnsKey, nowSeconds: number, cryptoKey?: CryptoKey): Promise<string> {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: key.keyId }));
  const claims = b64url(JSON.stringify({ iss: key.teamId, iat: nowSeconds }));
  const signingInput = `${header}.${claims}`;
  const k = cryptoKey ?? (await importApnsKey(key.p8));
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, k, new TextEncoder().encode(signingInput)),
  );
  return `${signingInput}.${b64url(sig)}`;
}

// Apple rejects tokens older than an hour and throttles refreshes faster
// than every 20 minutes; reuse one for 40 minutes per isolate.
let cachedToken: { keyId: string; token: string; issuedAt: number } | null = null;

export async function providerToken(key: ApnsKey, nowSeconds = Math.floor(Date.now() / 1000)): Promise<string> {
  if (cachedToken && cachedToken.keyId === key.keyId && nowSeconds - cachedToken.issuedAt < 40 * 60) {
    return cachedToken.token;
  }
  const token = await signApnsJwt(key, nowSeconds);
  cachedToken = { keyId: key.keyId, token, issuedAt: nowSeconds };
  return token;
}

// ---------- payloads ----------

function clip(s: string | null | undefined, max: number): string {
  if (!s) return "";
  const t = s.trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

export function displayAgent(agent: string | null | undefined): string {
  if (!agent) return "Agent";
  const known: Record<string, string> = { claude: "Claude", codex: "Codex", gemini: "Gemini", opencode: "OpenCode", amp: "Amp" };
  return known[agent.toLowerCase()] ?? agent.charAt(0).toUpperCase() + agent.slice(1);
}

export function threadId(hostId: string, surface: number | null): string {
  return surface === null ? `host-${hostId}` : `host-${hostId}-surface-${surface}`;
}

/// Category for an event. A question with parsed options still uses
/// FEED_QUESTION; the service extension swaps in a per-notification category
/// carrying the option buttons.
export function categoryFor(event: Pick<AttentionEvent, "kind">): string {
  return CATEGORY[event.kind] ?? "FEED_GENERIC";
}

export interface AlertPayloadInput {
  hostId: string;
  hostName?: string | null;
  event: AttentionEvent;
}

/// The alert payload. `mutable-content` lets the service extension render
/// the agent name and the prompt quote; `cmux` carries what the app needs to
/// answer and deep-link.
export function buildAlertPayload(input: AlertPayloadInput): Record<string, unknown> {
  const { event, hostId } = input;
  const subtitleParts = [event.agent ? displayAgent(event.agent) : null, event.workspace].filter(Boolean);
  const alert: Record<string, string> = {
    title: clip(event.title, 120) || defaultTitle(event),
    body: clip(event.body, 600) || defaultBody(event),
  };
  if (subtitleParts.length) alert.subtitle = clip(subtitleParts.join(" · "), 120);
  const aps: Record<string, unknown> = {
    alert,
    sound: "default",
    "thread-id": threadId(hostId, event.surface),
    category: categoryFor(event),
    "mutable-content": 1,
    "interruption-level": event.kind === "question" || event.kind === "permission" ? "time-sensitive" : "active",
    "relevance-score": event.kind === "question" || event.kind === "permission" ? 1 : event.kind === "done" ? 0.6 : 0.3,
  };
  const cmux = {
    v: 1,
    host_id: hostId,
    host_name: input.hostName ?? null,
    event_id: event.id,
    kind: event.kind,
    surface: event.surface,
    workspace: event.workspace,
    agent: event.agent,
    options: event.options.slice(0, 4).map((o) => ({ key: clip(o.key, 8), label: clip(o.label, 60) })),
    quote: clip(event.quote, 400) || null,
  };
  const payload = { aps, cmux };
  return fitPayload(payload);
}

function defaultTitle(e: AttentionEvent): string {
  const name = displayAgent(e.agent);
  switch (e.kind) {
    case "question":
      return `${name} needs your input`;
    case "permission":
      return `${name} is asking for permission`;
    case "done":
      return `${name} finished`;
    case "error":
      return `${name} hit an error`;
    default:
      return "cmux";
  }
}

function defaultBody(e: AttentionEvent): string {
  return e.workspace ? `In ${e.workspace}` : "Open cmux to see it.";
}

/// Trims the quote, then the body, until the JSON fits in 4 KB.
export function fitPayload(payload: { aps: Record<string, unknown>; cmux: Record<string, unknown> }): Record<string, unknown> {
  const size = () => new TextEncoder().encode(JSON.stringify(payload)).length;
  if (size() <= MAX_PAYLOAD_BYTES) return payload;
  payload.cmux.quote = null;
  const alert = payload.aps.alert as Record<string, string>;
  while (size() > MAX_PAYLOAD_BYTES && alert.body.length > 40) {
    alert.body = `${alert.body.slice(0, Math.floor(alert.body.length * 0.7))}…`;
  }
  return payload;
}

export function activityDetail(state: ActivityState, detail?: string | null): string {
  if (detail) return clip(detail, 120);
  return state === "working" ? "Working" : state === "needs_input" ? "Needs your input" : "Done";
}

/// Push-to-start (iOS 17.2+): starts `AgentActivityAttributes` on the device.
export function buildLiveActivityStartPayload(
  attributes: ActivityAttributes,
  content: ActivityContentState,
  nowSeconds: number,
): Record<string, unknown> {
  return {
    aps: {
      timestamp: nowSeconds,
      event: "start",
      "attributes-type": "AgentActivityAttributes",
      attributes,
      "content-state": content,
      "stale-date": nowSeconds + 4 * 3600,
      alert: {
        title: `${attributes.agent} is working`,
        body: attributes.workspace ? `In ${attributes.workspace}` : "On your Mac",
      },
    },
  };
}

export function buildLiveActivityUpdatePayload(
  content: ActivityContentState,
  nowSeconds: number,
  opts: { end?: boolean; alert?: { title: string; body: string } } = {},
): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    timestamp: nowSeconds,
    event: opts.end ? "end" : "update",
    "content-state": content,
  };
  if (opts.end) aps["dismissal-date"] = nowSeconds + 15 * 60;
  else aps["stale-date"] = nowSeconds + 4 * 3600;
  if (opts.alert) aps.alert = opts.alert;
  return { aps };
}

// ---------- transport ----------

export interface ApnsRequest {
  token: string;
  environment: ApnsEnvironment;
  topic: string;
  pushType: "alert" | "liveactivity" | "background";
  payload: Record<string, unknown>;
  priority?: 5 | 10;
  collapseId?: string;
  expirationSeconds?: number;
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  reason?: string;
  apnsId?: string | null;
}

export function apnsHost(environment: ApnsEnvironment): string {
  return environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
}

export function apnsHeaders(req: ApnsRequest, jwt: string): Record<string, string> {
  const h: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": req.topic,
    "apns-push-type": req.pushType,
    "apns-priority": String(req.priority ?? 10),
    "content-type": "application/json",
  };
  if (req.collapseId) h["apns-collapse-id"] = req.collapseId.slice(0, 64);
  if (req.expirationSeconds !== undefined) h["apns-expiration"] = String(req.expirationSeconds);
  return h;
}

/// `POST /3/device/<token>` over HTTP/2 (Workers negotiate h2 with APNs).
export async function sendApns(key: ApnsKey, req: ApnsRequest): Promise<ApnsResult> {
  const jwt = await providerToken(key);
  const r = await fetch(`${apnsHost(req.environment)}/3/device/${req.token}`, {
    method: "POST",
    headers: apnsHeaders(req, jwt),
    body: JSON.stringify(req.payload),
  });
  let reason: string | undefined;
  if (!r.ok) {
    try {
      reason = ((await r.json()) as { reason?: string }).reason;
    } catch {}
  }
  return { ok: r.ok, status: r.status, reason, apnsId: r.headers.get("apns-id") };
}

/// Tokens Apple says are gone; the device row should be dropped.
export function isDeadToken(result: ApnsResult): boolean {
  return result.status === 410 || (result.status === 400 && (result.reason === "BadDeviceToken" || result.reason === "DeviceTokenNotForTopic"));
}

// ---------- validation ----------

export function parseAttentionEvent(body: Record<string, unknown>): AttentionEvent {
  const kind = body.kind;
  if (typeof kind !== "string" || !(FEED_KINDS as readonly string[]).includes(kind)) throw new Error("kind");
  const id = body.id;
  if (typeof id !== "string" || id.length < 1 || id.length > 128) throw new Error("id");
  const s = (k: string, max: number): string | null => {
    const v = body[k];
    if (v === undefined || v === null) return null;
    if (typeof v !== "string") throw new Error(k);
    return v.slice(0, max);
  };
  const surface = body.surface;
  if (surface !== undefined && surface !== null && (typeof surface !== "number" || !Number.isInteger(surface))) throw new Error("surface");
  const rawOptions = Array.isArray(body.options) ? body.options : [];
  const options: FeedOption[] = [];
  for (const o of rawOptions.slice(0, 8)) {
    if (o && typeof o === "object" && typeof (o as FeedOption).key === "string" && typeof (o as FeedOption).label === "string") {
      options.push({ key: (o as FeedOption).key.slice(0, 8), label: (o as FeedOption).label.slice(0, 200) });
    }
  }
  const created = typeof body.created_at === "number" ? body.created_at : Date.now();
  return {
    id,
    kind: kind as FeedKind,
    title: s("title", 500) ?? "",
    body: s("body", 4000) ?? "",
    surface: typeof surface === "number" ? surface : null,
    workspace: s("workspace", 255),
    agent: s("agent", 64),
    options,
    quote: s("quote", 2000),
    created_at: created,
  };
}
