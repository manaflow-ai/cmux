export const DEFAULT_TURN_TTL_SECONDS = 3_600;
export const MIN_TURN_TTL_SECONDS = 300;
export const MAX_TURN_TTL_SECONDS = 172_800;

export interface TurnIceServer {
  readonly urls: string[];
  readonly username?: string;
  readonly credential?: string;
}

export interface TurnCredentialResponse {
  readonly iceServers: TurnIceServer[];
}

/** Keep the TTL server-owned and within Cloudflare's 48-hour maximum. */
export function normalizeTurnTTLSeconds(raw: string | undefined): number {
  const value = raw === undefined ? Number.NaN : Number(raw.trim());
  if (!Number.isSafeInteger(value) || value <= 0) return DEFAULT_TURN_TTL_SECONDS;
  return Math.min(MAX_TURN_TTL_SECONDS, Math.max(MIN_TURN_TTL_SECONDS, value));
}

export function turnCredentialsURL(keyID: string): string {
  return `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyID)}/credentials/generate-ice-servers`;
}

function stringValue(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeURLs(value: unknown): string[] {
  const values = Array.isArray(value) ? value : [value];
  return values
    .map(stringValue)
    .filter((url): url is string => url !== undefined && url.length <= 2_048)
    .slice(0, 32);
}

function normalizeServer(value: unknown): TurnIceServer | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const urls = normalizeURLs(record.urls);
  if (urls.length === 0) return null;
  const username = stringValue(record.username);
  const credential = stringValue(record.credential);
  if ((username === undefined) !== (credential === undefined)) return null;
  return {
    urls,
    ...(username === undefined ? {} : { username }),
    ...(credential === undefined ? {} : { credential }),
  };
}

/** Normalize both Cloudflare's current array response and its object form. */
export function decodeTurnCredentialResponse(value: unknown): TurnCredentialResponse | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = (value as Record<string, unknown>).iceServers;
  const entries = Array.isArray(raw) ? raw : [raw];
  const iceServers = entries
    .map(normalizeServer)
    .filter((server): server is TurnIceServer => server !== null);
  return iceServers.length > 0 ? { iceServers } : null;
}
