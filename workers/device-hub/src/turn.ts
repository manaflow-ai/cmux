import type { Env } from "./env";

export const ICE_TTL_S = 3600;

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

/**
 * Mints Cloudflare Realtime TURN credentials (TTL 1 h). Returns [] when
 * TURN_KEY_ID / TURN_KEY_API_TOKEN are not configured or the API fails; the
 * app then uses direct paths and the user's own relays.
 */
export async function mintTurn(env: Env): Promise<IceServer[]> {
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
