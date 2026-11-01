import type { SignalRoom } from "./signal";

export interface Env {
  SIGNAL_ROOM: DurableObjectNamespace<SignalRoom>;
  /** Cloudflare Email Service binding; absent until a sending domain is onboarded. */
  SEND_EMAIL?: { send(message: Record<string, unknown>): Promise<unknown> };

  APPLE_AUDIENCE: string;
  EMAIL_FROM: string;
  TEST_EMAIL_DOMAIN: string;
  /** Comma-separated exact addresses that may sign in with TEST_LOGIN_CODE. */
  TEST_LOGIN_EMAILS?: string;

  JWT_SECRET: string;
  TEST_LOGIN_CODE?: string;
  DATABASE_HOST: string;
  DATABASE_USERNAME: string;
  DATABASE_PASSWORD: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}
