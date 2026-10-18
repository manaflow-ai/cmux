import { env as workerEnv } from "cloudflare:workers";
import { createApp } from "../src/app";
import type { Mail } from "../src/context";
import type { AppEnv } from "../src/env";
import { MemoryRepo } from "../src/repo/memory";

export type FetchHandler = (url: string, init?: RequestInit) => Response | Promise<Response> | undefined;

/** A unit-test harness: in-memory repo, fixed clock, captured mail, scripted outbound fetch. */
export function harness(envOverrides: Partial<AppEnv> = {}) {
  const repo = new MemoryRepo();
  const mail: Mail[] = [];
  const clock = { now: 1_800_000_000_000 };
  const handlers: FetchHandler[] = [];
  const outbound: { url: string; init?: RequestInit }[] = [];
  const env: AppEnv = {
    ...(workerEnv as unknown as AppEnv),
    JWT_SECRET: "unit-secret",
    TEST_LOGIN_SECRET: undefined,
    AUTH_LIMITER: undefined,
    EMAIL_FROM: "login@example.com",
    ...envOverrides,
  };
  let mailEnabled = true;
  const app = createApp({
    repo: () => repo,
    now: () => clock.now,
    mailer: async (_env, m) => {
      if (!mailEnabled) return false;
      mail.push(m);
      return true;
    },
    fetch: async (input, init) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      outbound.push({ url, init });
      for (const h of handlers) {
        const res = await h(url, init);
        if (res) return res;
      }
      throw new Error(`unexpected outbound fetch ${url}`);
    },
  });

  async function call(method: string, path: string, opts: { body?: unknown; token?: string; headers?: Record<string, string> } = {}) {
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    if (opts.body !== undefined) headers["content-type"] = "application/json";
    if (opts.token) headers.authorization = `Bearer ${opts.token}`;
    const res = await app.request(
      `https://api.test${path}`,
      { method, headers, body: opts.body === undefined ? undefined : JSON.stringify(opts.body) },
      env,
    );
    const text = await res.text();
    let json: any = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = text;
    }
    return { status: res.status, json, headers: res.headers };
  }

  return {
    app,
    env,
    repo,
    mail,
    clock,
    outbound,
    onFetch: (h: FetchHandler) => handlers.push(h),
    setMailEnabled: (v: boolean) => {
      mailEnabled = v;
    },
    call,
  };
}

/** Extracts the 6-char code from the last mail. */
export function lastCode(mail: Mail[]): string {
  const m = mail.at(-1);
  const match = m?.text.match(/code is ([A-Z0-9]{6})/);
  if (!match) throw new Error("no code in mail");
  return match[1]!;
}

export async function emailLogin(h: ReturnType<typeof harness>, email = "a@example.com") {
  const start = await h.call("POST", "/v1/auth/email/start", { body: { email } });
  const verify = await h.call("POST", "/v1/auth/email/verify", { body: { email, code: lastCode(h.mail), nonce: start.json.nonce } });
  return verify.json as { accessToken: string; refreshToken: string; expiresIn: number; user: { id: string; email: string } };
}
