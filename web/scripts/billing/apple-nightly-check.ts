#!/usr/bin/env bun
// The Billing nightly's Apple checks (.github/workflows/billing-nightly.yml).
// Logic and tests: services/billing/apple/nightlyCheck.ts,
// tests/apple-iap-nightly-check.test.ts.
//
//   bun scripts/billing/apple-nightly-check.ts delivery \
//     --environment Sandbox|Production --bundle-id com.cmux.app \
//     --health-url https://cmux.com/api/cron/apple-notifications/health [--report FILE]
//   bun scripts/billing/apple-nightly-check.ts api \
//     --environment Sandbox --bundle-id com.cmux.app --original-transaction-id ID [--report FILE]
//
// Env: APPLE_IAP_KEY_ID, APPLE_IAP_ISSUER_ID, APPLE_IAP_PRIVATE_KEY (the
// In-App Purchase key the server uses); delivery also reads
// APPLE_NOTIFICATIONS_HEALTH_TOKEN. Secrets are sent only to Apple and to the
// health URL, never printed. Writes a Markdown summary to GITHUB_STEP_SUMMARY
// when set. Exit 0 pass, 1 check failed, 2 usage or missing configuration.

import { appendFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { AppStoreServerAPIClient, Environment } from "@apple/app-store-server-library";

import { appleServerApiCredentials } from "../../services/billing/apple/config";
import {
  appleClientForNightly,
  checkAppleDelivery,
  checkServerApi,
  type DeliveryReport,
  type ServerApiReport,
} from "../../services/billing/apple/nightlyCheck";

function fail(message: string): never {
  console.error(message);
  process.exit(2);
}

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    environment: { type: "string" },
    "bundle-id": { type: "string" },
    "health-url": { type: "string" },
    "original-transaction-id": { type: "string" },
    report: { type: "string" },
    "timeout-seconds": { type: "string" },
  },
});

const check = positionals[0];
if (check !== "delivery" && check !== "api") fail("usage: apple-nightly-check.ts delivery|api --environment ... --bundle-id ...");
const environment = values.environment;
if (environment !== "Sandbox" && environment !== "Production") fail("--environment must be Sandbox or Production");
const bundleId = values["bundle-id"]?.trim();
if (!bundleId) fail("--bundle-id is required");
const credentials = appleServerApiCredentials(process.env);
if (!credentials) fail("APPLE_IAP_KEY_ID, APPLE_IAP_ISSUER_ID and APPLE_IAP_PRIVATE_KEY are required");

const client = appleClientForNightly(new AppStoreServerAPIClient(
  credentials.privateKey,
  credentials.keyId,
  credentials.issuerId,
  bundleId,
  environment === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
));

function summarize(lines: string[]) {
  const text = lines.join("\n") + "\n";
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + "\n");
}

function save(report: DeliveryReport | ServerApiReport) {
  if (values.report) writeFileSync(values.report, JSON.stringify(report, null, 2) + "\n");
}

if (check === "delivery") {
  const healthUrl = values["health-url"]?.trim();
  if (!healthUrl?.startsWith("https://")) fail("--health-url must be an https URL");
  const token = process.env.APPLE_NOTIFICATIONS_HEALTH_TOKEN?.trim();
  if (!token) fail("APPLE_NOTIFICATIONS_HEALTH_TOKEN is required");
  const timeoutSeconds = Number(values["timeout-seconds"] ?? "300");
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0) fail("--timeout-seconds must be positive");

  const report = await checkAppleDelivery({
    client,
    environment,
    timeoutMs: timeoutSeconds * 1000,
    clock: { now: () => Date.now(), wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)) },
    readHealth: async (uuid) => {
      const url = new URL(healthUrl);
      url.searchParams.set("uuid", uuid);
      const response = await fetch(url, {
        headers: { authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(15_000),
      });
      let body: unknown = null;
      try {
        body = await response.json();
      } catch {
        body = { error: "non-JSON response" };
      }
      return { status: response.status, body };
    },
  });
  save(report);
  summarize([
    `### Apple delivery round trip: ${bundleId}, ${environment}: ${report.ok ? "pass" : "FAIL"}`,
    "",
    `| Step | Result |`,
    `| --- | --- |`,
    `| Apple reports delivery to our URL | ${report.appleDelivered ? "yes" : "no"} |`,
    `| Apple send attempts | ${report.attempts.map((a) => `${a.result} ${a.at ?? ""}`.trim()).join(", ") || "none"} |`,
    `| Notification UUID | ${report.notificationUuid ?? "none"} |`,
    `| Recorded in apple_notifications | ${report.recorded ? `yes, received ${report.receivedAt}, processed ${report.processedAt ?? "not yet"}` : "no"} |`,
    `| Elapsed | ${(report.elapsedMs / 1000).toFixed(1)} s |`,
    ...(report.failure ? ["", `**Failure:** ${report.failure}`] : []),
  ]);
  process.exit(report.ok ? 0 : 1);
} else {
  const originalTransactionId = values["original-transaction-id"]?.trim();
  if (!originalTransactionId) fail("--original-transaction-id is required");
  const report = await checkServerApi({ client, originalTransactionId });
  save(report);
  summarize([
    `### App Store Server API: ${bundleId}, ${environment}: ${report.ok ? "pass" : "FAIL"}`,
    "",
    report.ok
      ? `The key authenticated and the configured Sandbox subscription has Apple status ${report.status ?? "unknown"}.`
      : `**Failure:** ${report.failure?.replaceAll(originalTransactionId, "<configured transaction>")}`,
  ]);
  process.exit(report.ok ? 0 : 1);
}
