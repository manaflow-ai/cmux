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
  CODEROUTER_HOSTED_PRO_REQUIRED: "1",
  SUBROUTER_ENFORCE_STACK_PERMISSIONS: "0",
  SUBROUTER_ALLOWED_TEAM_IDS: "*",
};

const requiredSubrouterDeploymentEnv = {
  SUBROUTER_ADMIN_TOKEN: "test-legacy-subrouter-admin",
  SUBROUTER_STACK_TENANT_DELETE_TOKEN: "0123456789abcdef0123456789abcdef",
  SUBROUTER_ENFORCE_STACK_PERMISSIONS: "0",
  SUBROUTER_ALLOWED_TEAM_IDS: "test-team",
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

  test("requires the hosted coderouter Pro gate in Vercel production", () => {
    const {
      CODEROUTER_HOSTED_PRO_REQUIRED: _hostedProRequired,
      ...baseEnv
    } = requiredEnv;
    const result = importEnv({
      ...baseEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain(
      "CODEROUTER_HOSTED_PRO_REQUIRED is required for deployed production runtimes",
    );
  });

  test("rejects the retired annual Pro price override at startup", () => {
    const result = importEnv({
      ...requiredEnv,
      STRIPE_PRO_YEARLY_PRICE_ID: "price_grandfathered_240",
    });

    expect(result.exitCode).not.toBe(0);
    expect(result.stderr).toContain(
      "STRIPE_PRO_YEARLY_PRICE_ID is retired; use STRIPE_PRO_YEARLY_288_PRICE_ID",
    );
  });

  test("allows explicit Vercel production deployments with all rate-limit ids unset", () => {
    // Rate limiting is opt-in: production deploys must survive every
    // rate-limit id being deleted from the environment.
    const { CMUX_FEEDBACK_RATE_LIMIT_ID: _feedback, ...baseEnv } = requiredEnv;
    const result = importEnv({
      ...baseEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("RATE_LIMIT_ID");
  });

  test("accepts explicit Vercel production deployments with both limiter ids", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      CMUX_ANALYTICS_RATE_LIMIT_ID: "analytics-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.exitCode).toBe(0);
  });

  test("allows hosted-only production after the temporary legacy admin token is retired", () => {
    const { SUBROUTER_ADMIN_TOKEN: _legacyToken, ...hostedSubrouterEnv } =
      requiredSubrouterDeploymentEnv;
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      ...hostedSubrouterEnv,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("SUBROUTER_ADMIN_TOKEN");
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

  test("allows explicit Vercel production deployments without the analytics limiter id", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "production",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.exitCode).toBe(0);
    expect(result.stderr).not.toContain("CMUX_ANALYTICS_RATE_LIMIT_ID");
  });

  test("allows Vercel development without the analytics limiter id", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "development",
      CMUX_CLIENT_CONFIG_RATE_LIMIT_ID: "client-config-rule",
      ...requiredSubrouterDeploymentEnv,
    });

    expect(result.exitCode).toBe(0);
  });

  test("keeps Vercel previews credential-free", () => {
    const result = importEnv({
      ...requiredEnv,
      VERCEL: "1",
      VERCEL_ENV: "preview",
    });

    expect(result.exitCode).toBe(0);
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
