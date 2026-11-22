// A production deployment without the App Store Server API key would trust
// client transactions, skip renewal re-checks and skip the backfill without
// saying so. The cron now fails loudly there, and every fallback to the
// client's own transaction is logged under one metric name.

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

import { appleServerApiRequired, missingAppleServerApiEnv } from "../services/billing/apple/config";
import { runAppleIapCron } from "../services/billing/apple/cron";
import { recordClientAppleTransaction } from "../services/billing/apple/service";
import { createFixture, env, signer, transaction, type Fixture } from "./helpers/apple-iap-fixture";

let f: Fixture;
let warnings: unknown[][];
let errors: unknown[][];
let spies: ReturnType<typeof spyOn>[];

beforeEach(async () => {
  f = await createFixture();
  warnings = [];
  errors = [];
  spies = [
    spyOn(console, "warn").mockImplementation((...args: unknown[]) => {
      warnings.push(args);
    }),
    spyOn(console, "error").mockImplementation((...args: unknown[]) => {
      errors.push(args);
    }),
  ];
});

afterEach(() => {
  for (const spy of spies) spy.mockRestore();
});

const KEY_ENV = {
  APPLE_IAP_KEY_ID: "KEY123",
  APPLE_IAP_ISSUER_ID: "issuer",
  APPLE_IAP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
};

describe("Server API configuration", () => {
  test("names the missing env values, never their contents", () => {
    expect(missingAppleServerApiEnv(KEY_ENV)).toEqual([]);
    expect(missingAppleServerApiEnv({ ...KEY_ENV, APPLE_IAP_PRIVATE_KEY: " " })).toEqual(["APPLE_IAP_PRIVATE_KEY"]);
    expect(missingAppleServerApiEnv({})).toEqual(["APPLE_IAP_KEY_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_PRIVATE_KEY"]);
  });

  test("is required only in production deployments", () => {
    expect(appleServerApiRequired({ VERCEL_ENV: "production" })).toBe(true);
    expect(appleServerApiRequired({ VERCEL_ENV: "preview" })).toBe(false);
    expect(appleServerApiRequired({})).toBe(false);
  });

  test("the cron reports a production deployment without the key as a failure", async () => {
    const result = await runAppleIapCron(f.deps({ env: { ...env, VERCEL_ENV: "production", APPLE_IAP_KEY_ID: "KEY123" } }));
    expect(result.ok).toBe(false);
    expect(result.serverApi).toEqual({
      configured: false,
      missingInProduction: true,
      missingEnv: ["APPLE_IAP_ISSUER_ID", "APPLE_IAP_PRIVATE_KEY"],
    });
    expect(errors.some(([message]) => message === "apple_iap.server_api_not_configured")).toBe(true);
  });

  test("a non-production deployment without the key only warns", async () => {
    const result = await runAppleIapCron(f.deps({ env: { ...env, VERCEL_ENV: "preview" } }));
    expect(result.ok).toBe(true);
    expect(result.serverApi.missingInProduction).toBe(false);
    expect(warnings.some(([message]) => message === "apple_iap.server_api_not_configured")).toBe(true);
  });

  test("a configured deployment reports nothing", async () => {
    f.serverApi = f.statusApi(async () => null);
    const result = await runAppleIapCron(f.deps({ env: { ...env, VERCEL_ENV: "production" } }));
    expect(result.ok).toBe(true);
    expect(result.serverApi).toEqual({ configured: true, missingInProduction: false, missingEnv: [] });
    expect(result.history.configured).toBe(true);
  });
});

describe("client transaction fallback", () => {
  function fallbackReasons(): unknown[] {
    return warnings
      .filter(([message]) => message === "apple_iap.client_transaction_fallback")
      .map(([, context]) => (context as { reason: string }).reason);
  }

  test("is logged when the Server API is not configured", async () => {
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction({}, f.token)) }, f.deps());
    expect(fallbackReasons()).toEqual(["server_api_not_configured"]);
  });

  test("is logged when Apple's status lookup fails", async () => {
    f.serverApi = f.statusApi(async () => {
      throw new Error("503");
    });
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction({}, f.token)) }, f.deps());
    expect(fallbackReasons()).toEqual(["lookup_failed"]);
  });

  test("is logged when Apple has no status for the transaction", async () => {
    f.serverApi = f.statusApi(async () => null);
    await recordClientAppleTransaction({ userId: "user-a", signedTransactionInfo: signer.sign(transaction({}, f.token)) }, f.deps());
    expect(fallbackReasons()).toEqual(["no_status"]);
  });
});
