// Backend HTTP client (PROTOCOL.md §5): host pairing and ICE servers.

import type { ApiIceServer } from "../transport/webrtc.ts";
import { normalizeApi } from "../util.ts";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export interface PairStart {
  deviceCode: string;
  userCode: string;
  expiresAt: number | string;
  interval: number;
}

export type PairPoll = { status: "pending" } | { status: "approved"; hostId: string; hostToken: string; userId: string } | { status: string };

export class ApiClient {
  readonly base: string;

  constructor(
    base: string,
    private token?: string,
  ) {
    this.base = normalizeApi(base);
  }

  setToken(token: string | undefined): void {
    this.token = token;
  }

  async request<T>(method: string, path: string, body?: unknown, auth = true): Promise<T> {
    const headers: Record<string, string> = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (auth && this.token) headers.authorization = `Bearer ${this.token}`;
    const res = await fetch(`${this.base}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(20_000),
    });
    const text = await res.text();
    let json: any = {};
    try {
      json = text ? JSON.parse(text) : {};
    } catch {
      json = { error: { code: "bad_response", message: text.slice(0, 200) } };
    }
    if (!res.ok) {
      throw new ApiError(res.status, json?.error?.code ?? `http_${res.status}`, json?.error?.message ?? res.statusText);
    }
    return json as T;
  }

  pairStart(name: string, os: string): Promise<PairStart> {
    return this.request("POST", "/hosts/pair/start", { name, os }, false);
  }

  pairPoll(deviceCode: string): Promise<PairPoll> {
    return this.request("POST", "/hosts/pair/poll", { deviceCode }, false);
  }

  ice(): Promise<{ iceServers: ApiIceServer[]; ttl: number }> {
    return this.request("GET", "/ice");
  }

  /** wss://.../v1/signal?token=... */
  signalUrl(): string {
    const u = new URL(`${this.base}/signal`);
    u.protocol = u.protocol === "http:" ? "ws:" : "wss:";
    if (this.token) u.searchParams.set("token", this.token);
    return u.toString();
  }
}

/** Caches /v1/ice results until shortly before their ttl expires. */
export class IceCache {
  private value: ApiIceServer[] | null = null;
  private expires = 0;
  private inflight: Promise<ApiIceServer[]> | null = null;

  constructor(
    private readonly api: ApiClient,
    private readonly log: (m: string) => void = () => {},
  ) {}

  async get(): Promise<ApiIceServer[]> {
    if (this.value && Date.now() < this.expires) return this.value;
    if (!this.inflight) {
      this.inflight = this.api
        .ice()
        .then((r) => {
          this.value = r.iceServers ?? [];
          const ttl = typeof r.ttl === "number" && r.ttl > 0 ? r.ttl : 600;
          this.expires = Date.now() + Math.max(30, ttl * 0.8) * 1000;
          return this.value;
        })
        .catch((err) => {
          this.log(`ice fetch failed: ${(err as Error).message}; using public STUN only`);
          return this.value ?? [{ urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] }];
        })
        .finally(() => {
          this.inflight = null;
        });
    }
    return this.inflight;
  }
}
