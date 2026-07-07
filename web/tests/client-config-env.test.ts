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
    });

    expect(result.exitCode).toBe(0);
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
