import { EventEmitter } from "node:events";
import { describe, expect, mock, test } from "bun:test";

import { runWithCloudDbQuerySignal } from "../db/queryScope";

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

  test("cancels a scoped query while preserving pg promise behavior", async () => {
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
    const connection = Object.assign(new EventEmitter(), {
      parsedStatements: {} as Record<string, string>,
      query: () => undefined,
      stream: {
        writable: true,
        write: () => true,
        cork: () => undefined,
        uncork: () => undefined,
      },
    });
    const ClientConstructor = pool.options.Client as unknown as new (config?: unknown) => {
      readyForQuery: boolean;
      _connected: boolean;
      _activeQuery?: { handleError(error: Error, connection: unknown): void };
      cancel: () => void;
      end: () => Promise<void>;
      query: (text: string) => Promise<unknown>;
    };
    const client = new ClientConstructor({ connection });
    client.readyForQuery = true;
    client._connected = true;
    let cancelCalls = 0;
    let endCalls = 0;
    client.cancel = () => {
      cancelCalls += 1;
    };
    client.end = async () => {
      endCalls += 1;
    };

    const controller = new AbortController();
    const pending = runWithCloudDbQuerySignal(
      controller.signal,
      () => client.query("select 1"),
    );
    await Promise.resolve();
    expect(typeof pending.then).toBe("function");
    controller.abort(new Error("deadline"));
    expect(cancelCalls).toBe(1);
    expect(endCalls).toBe(1);

    const activeQuery = client._activeQuery;
    expect(activeQuery).toBeDefined();
    activeQuery?.handleError(new Error("query cancelled"), connection);
    await expect(pending).rejects.toThrow("query cancelled");
    client._activeQuery = undefined;
    client.readyForQuery = true;

    const secondController = new AbortController();
    const secondPending = runWithCloudDbQuerySignal(
      secondController.signal,
      () => client.query("select 1"),
    );
    await Promise.resolve();
    const secondQuery = client._activeQuery as { handleError(error: Error, connection: unknown): void } | undefined;
    secondQuery?.handleError(new Error("query failed"), connection);
    await expect(secondPending).rejects.toThrow("query failed");
    secondController.abort(new Error("late deadline"));
    expect(cancelCalls).toBe(1);
    expect(endCalls).toBe(1);
    await pool.end();
  });
});
