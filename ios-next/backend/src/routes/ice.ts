import { Hono } from "hono";
import { requireUserOrHost } from "../auth";
import type { HonoEnv } from "../context";
import { turnConfigured } from "../env";
import { ApiError } from "../errors";
import { userRateLimit } from "../signal/client";

export const STUN_URL = "stun:stun.cloudflare.com:3478";
export const ICE_TTL_S = 3600;
export const ICE_LIMIT = 60;
export const ICE_WINDOW_MS = 60 * 60 * 1000;

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

function normalize(raw: unknown): IceServer[] {
  const list = Array.isArray(raw) ? raw : raw && typeof raw === "object" ? [raw] : [];
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
}

export const iceRoutes = new Hono<HonoEnv>();

iceRoutes.get("/", requireUserOrHost, async (c) => {
  const { principal, repo } = c.var;
  // TURN credentials cost money: phones need a paired host to talk to.
  if (principal.kind === "user" && (await repo.listHosts(principal.userId)).length === 0) {
    throw new ApiError("forbidden", "pair a host first");
  }
  const key = principal.kind === "host" ? `ice:${principal.hostId}` : "ice:phone";
  if (!(await userRateLimit(c.env, principal.userId, key, ICE_LIMIT, ICE_WINDOW_MS))) throw new ApiError("rate_limited", "too many ICE requests");
  const iceServers: IceServer[] = [{ urls: [STUN_URL] }];
  if (turnConfigured(c.env)) {
    try {
      const res = await c.var.deps.fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(c.env.TURN_KEY_ID!)}/credentials/generate-ice-servers`,
        {
          method: "POST",
          headers: { authorization: `Bearer ${c.env.TURN_KEY_API_TOKEN}`, "content-type": "application/json" },
          body: JSON.stringify({ ttl: ICE_TTL_S }),
        },
      );
      if (!res.ok) throw new Error(`turn ${res.status}`);
      const body = (await res.json()) as { iceServers?: unknown };
      // Keep only servers that carry credentials (TURN); STUN is already listed.
      iceServers.push(...normalize(body.iceServers).filter((s) => s.username && s.credential));
    } catch (err) {
      console.error("turn credentials failed", err instanceof Error ? err.message : err);
    }
  }
  c.header("cache-control", "no-store");
  return c.json({ iceServers, ttl: ICE_TTL_S });
});
