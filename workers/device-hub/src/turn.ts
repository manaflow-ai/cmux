import type { Env } from "./env";

export const ICE_TTL_S = 3600;
/** Deadline for the platform's ICE answer before the hub falls back. */
export const PLATFORM_TURN_TIMEOUT_MS = 4500;

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/** Where the cmux relay ICE comes from (var `TURN_SOURCE`). Unknown or missing: `local`. */
export type TurnSource = "local" | "platform-first" | "platform";

export function turnSource(env: Env): TurnSource {
  const v = env.TURN_SOURCE?.trim();
  return v === "platform-first" || v === "platform" ? v : "local";
}

/**
 * The cmux relay ICE servers for a session (TTL 1 h). cmux-platform runs the one
 * TURN minter; the hub asks it (`POST /v1/relay/ice-servers`) and keeps its own
 * mint only as the fallback until that is removed:
 * - `local`: the hub mints itself (mintLocalTurn).
 * - `platform-first`: ask the platform; on a non-200, a timeout, a bad body or an
 *   empty list, warn and mint locally (which is [] without TURN_KEY_*).
 * - `platform`: the platform only, [] on any failure.
 * Without the DEVICE_HUB_TURN_TOKEN secret or PLATFORM_TURN_ORIGIN, every mode
 * behaves as `local`. Returns [] when nothing answers; the app then uses direct
 * paths and the user's own relays.
 */
export async function mintTurn(env: Env, opts: { timeoutMs?: number } = {}): Promise<IceServer[]> {
  const source = turnSource(env);
  const origin = platformOrigin(env.PLATFORM_TURN_ORIGIN);
  if (source === "local" || !env.DEVICE_HUB_TURN_TOKEN || !origin) return mintLocalTurn(env);
  const result = await platformTurn(origin, env.DEVICE_HUB_TURN_TOKEN, opts.timeoutMs ?? PLATFORM_TURN_TIMEOUT_MS);
  if (Array.isArray(result)) return result;
  if (source === "platform") {
    console.warn("platform turn failed", result.reason);
    return [];
  }
  console.warn("platform turn failed, minting locally", result.reason);
  return mintLocalTurn(env);
}

function platformOrigin(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const u = new URL(value.trim());
    return u.protocol === "https:" ? u.origin : null;
  } catch {
    return null;
  }
}

async function platformTurn(origin: string, token: string, timeoutMs: number): Promise<IceServer[] | { reason: string }> {
  let res: Response;
  try {
    res = await fetch(`${origin}/v1/relay/ice-servers`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ ttlSeconds: ICE_TTL_S }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    return { reason: name === "TimeoutError" || name === "AbortError" ? "timeout" : "network" };
  }
  if (res.status !== 200) {
    let code = "";
    try {
      const b = (await res.json()) as { error?: unknown };
      if (typeof b?.error === "string") code = ` ${b.error.slice(0, 64)}`;
    } catch {
      // Not JSON; the status says enough.
    }
    return { reason: `status ${res.status}${code}` };
  }
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return { reason: "bad body" };
  }
  const ice = parsePlatformIce(body);
  if (!ice) return { reason: "bad body" };
  if (ice.length === 0) return { reason: "empty ice" };
  return ice;
}

/** `{ice: [{urls: string[], username?: string, credential?: string}]}`, strictly; null otherwise. */
export function parsePlatformIce(body: unknown): IceServer[] | null {
  if (!body || typeof body !== "object") return null;
  const list = (body as { ice?: unknown }).ice;
  if (!Array.isArray(list)) return null;
  const out: IceServer[] = [];
  for (const item of list) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    const s = item as Record<string, unknown>;
    if (!Array.isArray(s.urls) || s.urls.length === 0 || !s.urls.every((u) => typeof u === "string" && u.length > 0)) return null;
    if (s.username !== undefined && typeof s.username !== "string") return null;
    if (s.credential !== undefined && typeof s.credential !== "string") return null;
    const server: IceServer = { urls: [...(s.urls as string[])] };
    if (typeof s.username === "string") server.username = s.username;
    if (typeof s.credential === "string") server.credential = s.credential;
    out.push(server);
  }
  return out;
}

/**
 * The hub's own mint: Cloudflare Realtime TURN credentials (TTL 1 h). The
 * fallback while the platform minter rolls out. Returns [] when TURN_KEY_ID /
 * TURN_KEY_API_TOKEN are not configured or the API fails.
 */
export async function mintLocalTurn(env: Env): Promise<IceServer[]> {
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return [];
  try {
    const res = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ ttl: ICE_TTL_S }),
    });
    if (!res.ok) throw new Error(`turn ${res.status}`);
    const body = (await res.json()) as { iceServers?: unknown };
    const list = Array.isArray(body.iceServers) ? body.iceServers : body.iceServers ? [body.iceServers] : [];
    const out: IceServer[] = [];
    for (const item of list) {
      if (!item || typeof item !== "object") continue;
      const s = item as Record<string, unknown>;
      const urls = (Array.isArray(s.urls) ? s.urls : [s.urls]).filter((u): u is string => typeof u === "string");
      if (urls.length === 0) continue;
      const server: IceServer = { urls };
      if (typeof s.username === "string") server.username = s.username;
      if (typeof s.credential === "string") server.credential = s.credential;
      out.push(server);
    }
    return out;
  } catch (err) {
    console.error("turn credentials failed", err instanceof Error ? err.message : String(err));
    return [];
  }
}
