import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";

const requiredEnv = {
  PATH: process.env.PATH ?? "",
  HOME: process.env.HOME ?? "",
  RESEND_API_KEY: "test-resend",
  CMUX_FEEDBACK_FROM_EMAIL: "hello@example.com",
  CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rule",
  STACK_SECRET_SERVER_KEY: "stack-secret",
  NEXT_PUBLIC_STACK_PROJECT_ID: "stack-project",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "stack-public",
};

const requiredIrohProductionEnv = {
  CMUX_IROH_LAN_DISCOVERY_SECRET_B64: Buffer.alloc(32, 0x11).toString("base64"),
  CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: Buffer.alloc(32, 0x22).toString("base64"),
  CMUX_IROH_GRANT_SIGNING_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${"A".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_IROH_GRANT_SIGNING_KID: "current",
  CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON: "{}",
  CMUX_IROH_MINT_URL: "https://iroh-minter.example.com/api/relay-token",
  CMUX_IROH_MINT_HMAC_SECRET_B64: Buffer.alloc(32, 0x33).toString("base64"),
  CMUX_IROH_RATE_LIMIT_ID: "iroh-rule",
};

describe("client config env validation", () => {
  test("allows local builds with VERCEL set but no deployment environment", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_PREVIEW_COMMENTS_ENABLED: "0",
    });

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID is required");
  });

  test("requires the limiter id in explicit Vercel production deployments", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("CMUX_CLIENT_CONFIG_RATE_LIMIT_ID is required");
  });

  test("accepts explicit Vercel production deployments with the limiter id", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredIrohProductionEnv,
    });

    expect(result.exitCode).toBe(0);
  });

  test("requires the Iroh limiter id in explicit Vercel production deployments", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("CMUX_IROH_RATE_LIMIT_ID is required");
  });

  test("requires the complete Iroh trust-broker configuration in production", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_IROH_RATE_LIMIT_ID: "iroh-rule",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("CMUX_IROH_GRANT_SIGNING_KEY_P8 is required");
    expect(result.stderr).toContain("CMUX_IROH_MINT_HMAC_SECRET_B64 is required");
  });
});

function importEnv(env: Record<string, string>): { exitCode: number; stderr: string } {
  const result = spawnSync(
    process.execPath,
    ["-e", "await import('./app/env')"],
    {
      env: env as NodeJS.ProcessEnv,
      encoding: "utf8",
    },
  );
  return {
    exitCode: result.status ?? 1,
    stderr: result.stderr,
  };
}
