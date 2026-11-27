import { EventEmitter } from "node:events";
import { describe, expect, mock, test } from "bun:test";

// Production 2026-11-25 and 2026-11-27: every database-backed route (the VM
// list, exec, dashboard RPCs, cron runs) on some instances ran to Vercel's
// 960 s maxDuration in the same minutes. The RDS pool (IAM token per
// connection) had no connection timeout, so a connect that never finished,
// and every request queued behind the full pool, waited forever. The pool now
// gives up on a connect or a queue wait, and the route answers its existing
// retryable database error.

mock.module("@vercel/oidc-aws-credentials-provider", () => ({
  awsCredentialsProvider: () => async () => ({ accessKeyId: "test", secretAccessKey: "test" }),
}));

const { createAwsRdsIamPool, CLOUD_DB_CONNECT_TIMEOUT_MS } = await import("../db/client");

const config = {
  driver: "aws-rds-iam" as const,
  awsRegion: "us-west-2",
  awsRoleArn: "arn:aws:iam::123456789012:role/vercel",
  host: "db.example.com",
  port: 5432,
  user: "postgres",
  database: "postgres",
  poolMax: 1,
  sslRejectUnauthorized: true,
};

/** A client whose connect never answers, like a stalled IAM token fetch or TCP connect. */
class NeverConnectingClient extends EventEmitter {
  connect(_callback: (err?: Error) => void) {
    // Never calls back until end().
    this.pending = _callback;
  }
  pending: ((err?: Error) => void) | undefined;
  isConnected() { return false; }
  end(callback?: () => void) {
    this.pending?.(new Error("ended before connecting"));
    this.pending = undefined;
    callback?.();
  }
}

describe("RDS pool connection timeout", () => {
  test("the production pool has a connection timeout inside the VM list's 20 s budget", () => {
    const pool = createAwsRdsIamPool(config);
    const timeout = (pool as unknown as { options: { connectionTimeoutMillis?: number } }).options.connectionTimeoutMillis;
    expect(timeout).toBe(CLOUD_DB_CONNECT_TIMEOUT_MS);
    expect(CLOUD_DB_CONNECT_TIMEOUT_MS).toBeGreaterThan(0);
    expect(CLOUD_DB_CONNECT_TIMEOUT_MS).toBeLessThan(20_000);
    void pool.end();
  });

  test("a connect that never finishes fails the query at the timeout instead of hanging", async () => {
    const pool = createAwsRdsIamPool(config, {
      Client: NeverConnectingClient as never,
      connectionTimeoutMillis: 50,
    });
    const startedAt = performance.now();
    const error = await pool.query("select 1").then(() => null, (err: unknown) => err as Error);
    expect(error?.message).toMatch(/timeout/i);
    expect(performance.now() - startedAt).toBeLessThan(2_000);
  });

  test("a request queued behind a stuck connection fails at the timeout instead of hanging", async () => {
    const pool = createAwsRdsIamPool(config, {
      Client: NeverConnectingClient as never,
      connectionTimeoutMillis: 50,
    });
    const first = pool.query("select 1").then(() => null, (err: unknown) => err as Error);
    const queued = pool.query("select 2").then(() => null, (err: unknown) => err as Error);
    const [a, b] = await Promise.all([first, queued]);
    expect(a?.message).toMatch(/timeout/i);
    expect(b?.message).toMatch(/timeout/i);
  });
});
