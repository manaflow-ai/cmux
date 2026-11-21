import type { Env } from "./env";

export const ICE_TTL_S = 3600;

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/**
 * cmux-platform's TurnMinter entrypoint (its src/server/cloud/TurnMinter.ts),
 * reached over the TURN_MINTER service binding: the platform's one TURN minter,
 * with the platform's own key. A same-account binding needs no shared secret.
 */
export interface TurnMinter {
  ice(options: { ttlS: number }): Promise<unknown>;
}

/**
 * The cmux relay ICE servers for a session (TTL 1 h). The hub asks
 * cmux-platform's one TURN minter over the TURN_MINTER binding first. If the
 * binding is missing, throws, answers badly or answers an empty list (the
 * platform has no TURN key yet), the hub mints locally (mintLocalTurn), which is
 * [] without TURN_KEY_*. The local mint is removed once the platform has its key.
 * Returns [] when nothing answers; the app then uses direct paths and the user's
 * own relays. Who gets the relay is decided before this call (userDo.ts).
 */
export async function mintTurn(env: Env): Promise<IceServer[]> {
  const result = await platformTurn(env.TURN_MINTER);
  if (Array.isArray(result)) return result;
  if (result.reason !== "unbound") console.warn("platform turn failed, minting locally", result.reason);
  return mintLocalTurn(env);
}

async function platformTurn(minter: TurnMinter | undefined): Promise<IceServer[] | { reason: string }> {
  if (!minter) return { reason: "unbound" };
  let answer: unknown;
  try {
    answer = await minter.ice({ ttlS: ICE_TTL_S });
  } catch (err) {
    return { reason: `rpc ${err instanceof Error ? err.name : "error"}` };
  }
  const ice = parsePlatformIce(answer);
  if (!ice) return { reason: "bad answer" };
  if (ice.length === 0) return { reason: "empty ice" };
  return ice;
}

/** `[{urls: string[], username?: string, credential?: string}]`, strictly; null otherwise. */
export function parsePlatformIce(list: unknown): IceServer[] | null {
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
