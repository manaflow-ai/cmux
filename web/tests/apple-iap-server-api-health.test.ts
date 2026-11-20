// Whether this deployment has the App Store Server API key is checkable
// without waiting for the cron: logged once at server start, and reported by
// the admin subscription analytics endpoint.

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";

// Namespace imports, so the file loads (and fails on its assertions) before
// these exports exist.
import * as appleConfig from "../services/billing/apple/config";
import * as startup from "../services/billing/apple/startupCheck";

const KEY_ENV = {
  APPLE_IAP_KEY_ID: "KEY123",
  APPLE_IAP_ISSUER_ID: "issuer",
  APPLE_IAP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
};

let errors: unknown[][];
let warnings: unknown[][];
let spies: ReturnType<typeof spyOn>[];

beforeEach(() => {
  errors = [];
  warnings = [];
  spies = [
    spyOn(console, "error").mockImplementation((...args: unknown[]) => { errors.push(args); }),
    spyOn(console, "warn").mockImplementation((...args: unknown[]) => { warnings.push(args); }),
  ];
});

afterEach(() => {
  for (const spy of spies) spy.mockRestore();
});

describe("App Store Server API status", () => {
  test("reports configured or missing, the missing names, and whether this deployment requires it", () => {
    expect(appleConfig.appleServerApiStatus?.({ ...KEY_ENV, VERCEL_ENV: "production" })).toEqual({
      appleServerApi: "configured", required: true, missingEnv: [],
    });
    expect(appleConfig.appleServerApiStatus?.({ VERCEL_ENV: "production", APPLE_IAP_KEY_ID: "KEY123" })).toEqual({
      appleServerApi: "missing", required: true, missingEnv: ["APPLE_IAP_ISSUER_ID", "APPLE_IAP_PRIVATE_KEY"],
    });
    expect(appleConfig.appleServerApiStatus?.({ VERCEL_ENV: "preview" })).toMatchObject({ appleServerApi: "missing", required: false });
  });

  test("server start logs an error when production is missing the key", () => {
    startup.reportAppleServerApiAtStartup?.({ VERCEL_ENV: "production" });
    expect(errors.some(([message]) => message === "apple_iap.server_api_not_configured")).toBe(true);
    const [, context] = errors.find(([message]) => message === "apple_iap.server_api_not_configured")!;
    expect(context).toMatchObject({ source: "startup", production: true });
  });

  test("server start only warns elsewhere and stays quiet when configured", () => {
    startup.reportAppleServerApiAtStartup?.({ VERCEL_ENV: "preview" });
    expect(errors).toEqual([]);
    expect(warnings.some(([message]) => message === "apple_iap.server_api_not_configured")).toBe(true);
    warnings = [];
    startup.reportAppleServerApiAtStartup?.({ ...KEY_ENV, VERCEL_ENV: "production" });
    expect(errors).toEqual([]);
    expect(warnings).toEqual([]);
  });
});
