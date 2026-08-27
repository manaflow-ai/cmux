import { describe, expect, test } from "bun:test";
import { cloudDbConfig } from "../db/config";

describe("cloud DB config", () => {
  test("uses a direct URL when DATABASE_URL is present", () => {
    expect(
      cloudDbConfig({
        DATABASE_URL: "postgres://cmux:cmux@localhost:15432/cmux",
      }).driver,
    ).toBe("url");
  });

  test("uses Vercel Marketplace Aurora OIDC env when requested", () => {
    const config = cloudDbConfig({
      CMUX_DB_DRIVER: "aws-rds-iam",
      AWS_REGION: "us-west-2",
      AWS_ROLE_ARN: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
      PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
      PGPORT: "5432",
      PGUSER: "cmux_app",
      PGDATABASE: "cmux",
      CMUX_DB_POOL_MAX: "3",
      CMUX_DB_SSL_REJECT_UNAUTHORIZED: "true",
      CMUX_DB_SSL_CA_PEM_BASE64: Buffer.from("-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----").toString("base64"),
    });

    expect(config).toEqual({
      driver: "aws-rds-iam",
      awsRegion: "us-west-2",
      awsRoleArn: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
      host: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
      port: 5432,
      user: "cmux_app",
      database: "cmux",
      poolMax: 3,
      sslRejectUnauthorized: true,
      sslCaPem: "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----",
    });
  });

  test("auto-detects Vercel Marketplace Aurora OIDC env without DATABASE_URL", () => {
    const config = cloudDbConfig({
      AWS_REGION: "us-west-2",
      AWS_ROLE_ARN: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
      PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
      PGPORT: "5432",
      PGUSER: "cmux_app",
      PGDATABASE: "cmux",
    });
    expect(config.driver).toBe("aws-rds-iam");
    if (config.driver !== "aws-rds-iam") throw new Error("expected aws-rds-iam config");
    expect(config.sslRejectUnauthorized).toBe(true);
  });

  test("allows explicitly disabling RDS certificate verification only when requested", () => {
    const config = cloudDbConfig({
      CMUX_DB_SSL_REJECT_UNAUTHORIZED: "false",
      AWS_REGION: "us-west-2",
      AWS_ROLE_ARN: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
      PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
      PGPORT: "5432",
      PGUSER: "cmux_app",
      PGDATABASE: "cmux",
    });

    expect(config.driver).toBe("aws-rds-iam");
    if (config.driver !== "aws-rds-iam") throw new Error("expected aws-rds-iam config");
    expect(config.sslRejectUnauthorized).toBe(false);
  });

  test("rejects malformed base64 CA bundles", () => {
    expect(() =>
      cloudDbConfig({
        AWS_REGION: "us-west-2",
        AWS_ROLE_ARN: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
        PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
        PGPORT: "5432",
        PGUSER: "cmux_app",
        PGDATABASE: "cmux",
        CMUX_DB_SSL_CA_PEM_BASE64: "not base64!!!",
      }),
    ).toThrow("CMUX_DB_SSL_CA_PEM_BASE64 must be valid base64");
  });

  test("auto-detects Vercel Marketplace Aurora OIDC env without explicit driver", () => {
    expect(
      cloudDbConfig({
        AWS_REGION: "us-west-2",
        AWS_ROLE_ARN: "arn:aws:iam::123456789012:role/vercel-cmux-staging",
        PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
        PGPORT: "5432",
        PGUSER: "cmux_app",
        PGDATABASE: "cmux",
      }).driver,
    ).toBe("aws-rds-iam");
  });

  test("reports missing Vercel Marketplace Aurora env names without values", () => {
    expect(() =>
      cloudDbConfig({
        CMUX_DB_DRIVER: "aws-rds-iam",
        AWS_REGION: "us-west-2",
        PGHOST: "cmux-staging.cluster-example.us-west-2.rds.amazonaws.com",
      }),
    ).toThrow("AWS_ROLE_ARN, PGPORT, PGUSER, PGDATABASE");
  });
});
