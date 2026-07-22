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

const requiredRelayProductionEnv = {
  CMUX_RELAY_JWT_PRIVATE_KEY_PEM:
    `-----BEGIN PRIVATE KEY-----\n${"B".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_RELAY_POLICY_KEY_ID: "relay-policy-current",
  CMUX_RELAY_POLICY_PRIVATE_KEY_PEM:
    `-----BEGIN PRIVATE KEY-----\n${"C".repeat(64)}\n-----END PRIVATE KEY-----`,
  CMUX_RELAY_TOKEN_RATE_LIMIT_ID: "relay-token-rule",
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

  test("accepts explicit Vercel production deployments with both limiter ids", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
    });

    expect(result.exitCode).toBe(0);
  });

  test("allows credential-free docs channel deployments", () => {
    const result = importEnv({
      PATH: requiredEnv.PATH,
      HOME: requiredEnv.HOME,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_DOCS_CHANNEL: "nightly",
    });

    expect(result.exitCode).toBe(0);
  });

  test("requires the analytics limiter id in explicit Vercel production deployments", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("CMUX_ANALYTICS_RATE_LIMIT_ID is required");
  });

  test("allows Vercel development without the analytics limiter id", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "development",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredIrohProductionEnv,
      ...requiredRelayProductionEnv,
    });

    expect(result.exitCode).toBe(0);
  });
  test("accepts the self-hosted relay path without the legacy hosted minter", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      CMUX_IROH_LAN_DISCOVERY_SECRET_B64: requiredIrohProductionEnv.CMUX_IROH_LAN_DISCOVERY_SECRET_B64,
      CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64: requiredIrohProductionEnv.CMUX_IROH_ACCOUNT_SUBJECT_SECRET_B64,
      CMUX_IROH_GRANT_SIGNING_KEY_P8: requiredIrohProductionEnv.CMUX_IROH_GRANT_SIGNING_KEY_P8,
      CMUX_IROH_GRANT_SIGNING_KID: requiredIrohProductionEnv.CMUX_IROH_GRANT_SIGNING_KID,
      CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON:
        requiredIrohProductionEnv.CMUX_IROH_GRANT_VERIFICATION_KEYS_JSON,
      CMUX_IROH_RATE_LIMIT_ID: requiredIrohProductionEnv.CMUX_IROH_RATE_LIMIT_ID,
      ...requiredRelayProductionEnv,
    });

    expect(result.exitCode).toBe(0);
  });

  test("requires the Iroh limiter id in explicit Vercel production deployments", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
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
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      CMUX_IROH_RATE_LIMIT_ID: "iroh-rule",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("CMUX_IROH_GRANT_SIGNING_KEY_P8 is required");
    expect(result.stderr).not.toContain("CMUX_IROH_MINT_HMAC_SECRET_B64 is required");
  });

  test("requires the self-hosted relay signing and rate-limit configuration in production", () => {
    const result = importEnv({
      ...requiredEnv,
      ...requiredIrohProductionEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain("Self-hosted relay runtime configuration is incomplete");
    expect(result.stderr).not.toContain("CMUX_RELAY_JWT_PRIVATE_KEY_PEM");
    expect(result.stderr).not.toContain("CMUX_RELAY_POLICY_KEY_ID");
    expect(result.stderr).not.toContain("CMUX_RELAY_POLICY_PRIVATE_KEY_PEM");
    expect(result.stderr).not.toContain("CMUX_RELAY_TOKEN_RATE_LIMIT_ID");
  });

  test("keeps Vercel previews credential-free for the self-hosted relay fleet", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "preview",
    });

    expect(result.exitCode).toBe(0);
  });

  test("allows an explicitly opted-in loopback HTTP relay minter only in local development", () => {
    const result = inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "development",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe("http://localhost:49152/api/relay-token");
  });

  test("rejects a plaintext non-loopback relay minter in local development", () => {
    const result = inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "development",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://192.168.1.10:49152/api/relay-token",
    });

    expect(result.exitCode).not.toBe(0);
  });

  test("rejects the insecure loopback opt-in in Vercel preview and production", () => {
    const preview = inspectIrohMinterUrl({
      ...requiredEnv,
      NODE_ENV: "production",
      VERCEL: "1",
      VERCEL_ENV: "preview",
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });
    expect(preview.exitCode).not.toBe(0);

    const production = inspectIrohMinterUrl({
      ...requiredEnv,
      ...requiredIrohProductionEnv,
      NODE_ENV: "production",
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredRelayProductionEnv,
      CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER: "1",
      CMUX_IROH_MINT_URL: "http://localhost:49152/api/relay-token",
    });
    expect(production.exitCode).not.toBe(0);
    expect(production.stderr).toContain(
      "CMUX_IROH_DEV_ALLOW_INSECURE_LOOPBACK_MINTER is only allowed in local development",
    );
  });
});

function importEnv(env: Record<string, string>): { exitCode: number; stderr: string } {
  const result = spawnSync(
    process.execPath,
    ["--no-env-file", "-e", "await import('./app/env')"],
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

function inspectIrohMinterUrl(
  env: Record<string, string>,
): { exitCode: number; stdout: string; stderr: string } {
  const result = spawnSync(
    process.execPath,
    [
      "--no-env-file",
      "-e",
      `
        const { irohTrustBrokerConfigFromEnv } = await import('./services/iroh/config');
        const { parseMinterUrl } = await import('./services/iroh/relayMinter');
        const config = irohTrustBrokerConfigFromEnv();
        const url = parseMinterUrl(config.relayMinterUrl, {
          allowInsecureLoopback: config.relayMinterInsecureLoopbackOptIn,
          deploymentEnvironment: config.deploymentEnvironment,
          isVercelDeployment: config.isVercelDeployment,
        });
        console.log(url.href);
      `,
    ],
    {
      env: env as NodeJS.ProcessEnv,
      encoding: "utf8",
    },
  );
  return {
    exitCode: result.status ?? 1,
    stdout: result.stdout.trim(),
    stderr: result.stderr,
  };
}
