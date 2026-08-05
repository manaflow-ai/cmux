import { describe, expect, mock, test } from "bun:test";

let oidcProviderCalls = 0;
mock.module("@vercel/oidc-aws-credentials-provider", () => ({
  awsCredentialsProvider: () => {
    oidcProviderCalls += 1;
    return async () => ({
      accessKeyId: "test",
      secretAccessKey: "test",
    });
  },
}));

const { createAwsRdsIamPool } = await import("../db/client");

describe("Vercel RDS IAM credentials", () => {
  test("always configures the Vercel OIDC provider for AWS RDS pools", async () => {
    const previous = process.env.VERCEL_OIDC_TOKEN;
    delete process.env.VERCEL_OIDC_TOKEN;
    const pool = createAwsRdsIamPool({
      driver: "aws-rds-iam",
      awsRegion: "us-west-2",
      awsRoleArn: "arn:aws:iam::123456789012:role/vercel",
      host: "db.example.com",
      port: 5432,
      user: "postgres",
      database: "postgres",
      poolMax: 1,
      sslRejectUnauthorized: true,
    });
    if (previous) process.env.VERCEL_OIDC_TOKEN = previous;

    expect(oidcProviderCalls).toBe(1);
    await pool.end();
  });
});
