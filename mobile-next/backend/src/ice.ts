import type { Env } from "./env";

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

const STUN_ONLY: IceServer[] = [{ urls: ["stun:stun.cloudflare.com:3478"] }];
const TTL = 86400;

export async function iceServers(env: Env): Promise<{ ice_servers: IceServer[]; ttl: number }> {
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return { ice_servers: STUN_ONLY, ttl: TTL };
  try {
    const res = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
        body: JSON.stringify({ ttl: TTL }),
      },
    );
    if (!res.ok) throw new Error(`turn ${res.status}`);
    const body = (await res.json()) as { iceServers: unknown };
    const list = (Array.isArray(body.iceServers) ? body.iceServers : [body.iceServers]) as Array<{
      urls: string | string[];
      username?: string;
      credential?: string;
    }>;
    const servers = list.map((s) => ({
      urls: Array.isArray(s.urls) ? s.urls : [s.urls],
      ...(s.username ? { username: s.username } : {}),
      ...(s.credential ? { credential: s.credential } : {}),
    }));
    return { ice_servers: servers, ttl: TTL };
  } catch (err) {
    console.error("turn credentials failed", (err as Error).message);
    return { ice_servers: STUN_ONLY, ttl: TTL };
  }
}
