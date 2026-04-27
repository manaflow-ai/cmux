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
    });
  });

  test("auto-detects Vercel Marketplace Aurora OIDC env without DATABASE_URL", () => {
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
