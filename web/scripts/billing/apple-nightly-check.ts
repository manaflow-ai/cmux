#!/usr/bin/env bun
// The Billing nightly's Apple checks (.github/workflows/billing-nightly.yml).
// Logic and tests: services/billing/apple/nightlyCheck.ts,
// tests/apple-iap-nightly-check.test.ts.
//
//   bun scripts/billing/apple-nightly-check.ts delivery \
//     --environment Sandbox|Production --bundle-id com.cmux.app \
//     --health-url https://cmux.com/api/cron/apple-notifications/health [--report FILE]
//   bun scripts/billing/apple-nightly-check.ts post-release --bundle-id com.cmux.app \
//     --health-url https://cmux.com/api/cron/apple-notifications/health [--cursor-timeout-seconds 2100]
//   bun scripts/billing/apple-nightly-check.ts api \
//     --environment Sandbox --bundle-id com.cmux.app --original-transaction-id ID [--report FILE]
//
// Env: APPLE_IAP_KEY_ID, APPLE_IAP_ISSUER_ID, APPLE_IAP_PRIVATE_KEY (the
// In-App Purchase key the server uses); delivery also reads
// APPLE_NOTIFICATIONS_HEALTH_TOKEN, and APPLE_IAP_PRODUCTION_RELEASED (`1`
// once the app has its first App Store release; until then a Production 401
// with a working Sandbox is a neutral note, not a failure). Secrets are sent only to Apple and to the
// health URL, never printed. Writes a Markdown summary to GITHUB_STEP_SUMMARY
// when set. Exit 0 pass, 1 check failed, 2 usage or missing configuration.

import { appendFileSync, writeFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { AppStoreServerAPIClient, Environment } from "@apple/app-store-server-library";

import { appleServerApiCredentials, isAcceptedAppleBundleId } from "../../services/billing/apple/config";
import {
  appleClientForNightly,
  checkAppleDelivery,
  checkPostRelease,
  checkServerApi,
  historyCount,
  sandboxAcceptsKey,
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
    "cursor-timeout-seconds": { type: "string" },
  },
});

const check = positionals[0];
if (check !== "delivery" && check !== "api" && check !== "post-release") {
  fail("usage: apple-nightly-check.ts delivery|api|post-release --environment ... --bundle-id ...");
}
// The post-release check is Production only.
const environment = check === "post-release" ? values.environment ?? "Production" : values.environment;
if (check === "post-release" && environment !== "Production") fail("post-release runs in Production only");
if (environment !== "Sandbox" && environment !== "Production") fail("--environment must be Sandbox or Production");
const bundleId = values["bundle-id"]?.trim();
if (!bundleId) fail("--bundle-id is required");
const credentials = appleServerApiCredentials(process.env);
if (!credentials) fail("APPLE_IAP_KEY_ID, APPLE_IAP_ISSUER_ID and APPLE_IAP_PRIVATE_KEY are required");

const apiClient = (target: "Production" | "Sandbox") => new AppStoreServerAPIClient(
  credentials.privateKey,
  credentials.keyId,
  credentials.issuerId,
  bundleId,
  target === "Production" ? Environment.PRODUCTION : Environment.SANDBOX,
);
const client = appleClientForNightly(apiClient(environment));

function summarize(lines: string[]) {
  const text = lines.join("\n") + "\n";
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + "\n");
}

function save(report: DeliveryReport | ServerApiReport) {
  if (values.report) writeFileSync(values.report, JSON.stringify(report, null, 2) + "\n");
}

/** Reads the authenticated health endpoint with `params`; throws on a network error or timeout. */
async function readHealthUrl(healthUrl: string, token: string, params: Record<string, string>) {
  const url = new URL(healthUrl);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);
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
}

const realClock = { now: () => Date.now(), wait: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)) };

if (check === "post-release") {
  const healthUrl = values["health-url"]?.trim();
  if (!healthUrl?.startsWith("https://")) fail("--health-url must be an https URL");
  const token = process.env.APPLE_NOTIFICATIONS_HEALTH_TOKEN?.trim();
  if (!token) fail("APPLE_NOTIFICATIONS_HEALTH_TOKEN is required");
  const cursorTimeoutSeconds = Number(values["cursor-timeout-seconds"] ?? "2100");
  if (!Number.isFinite(cursorTimeoutSeconds) || cursorTimeoutSeconds <= 0) fail("--cursor-timeout-seconds must be positive");
  const deliveryTimeoutSeconds = Number(values["timeout-seconds"] ?? "300");
  if (!Number.isFinite(deliveryTimeoutSeconds) || deliveryTimeoutSeconds <= 0) fail("--timeout-seconds must be positive");
  if (!isAcceptedAppleBundleId(bundleId)) fail(`--bundle-id ${bundleId} is not an accepted bundle (APPLE_IAP_BUNDLE_IDS)`);
  const report = await checkPostRelease({
    client,
    clock: realClock,
    readHealth: (uuid) => readHealthUrl(healthUrl, token, { uuid }),
    readCursor: () => readHealthUrl(healthUrl, token, { cursor: "Production", bundle: bundleId }),
    productionHistory: () => historyCount(apiClient("Production"), Date.now()),
    cursorTimeoutMs: cursorTimeoutSeconds * 1000,
    timeoutMs: deliveryTimeoutSeconds * 1000,
  });
  if (values.report) writeFileSync(values.report, JSON.stringify(report, null, 2) + "\n");
  summarize([
    `### Post-release check: ${bundleId}, Production: ${report.ok ? "pass" : "FAIL"}`,
    "",
    "| Step | Result | Detail |",
    "| --- | --- | --- |",
    ...report.steps.map((step) => `| ${step.name} | ${step.ok ? "pass" : "FAIL"} | ${step.detail.replaceAll("|", "\\|")} |`),
  ]);
  process.exit(report.ok ? 0 : 1);
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
    productionLock: {
      sandboxAccepts: () => sandboxAcceptsKey(apiClient("Sandbox"), Date.now()),
      released: process.env.APPLE_IAP_PRODUCTION_RELEASED?.trim() === "1",
    },
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
  if (report.note) console.log(`::notice title=Apple delivery (${environment})::${report.note}`);
  const verdict = report.lockedUntilRelease ? "locked until the first App Store release (neutral)" : report.ok ? "pass" : "FAIL";
  summarize([
    `### Apple delivery round trip: ${bundleId}, ${environment}: ${verdict}`,
    "",
    `| Step | Result |`,
    `| --- | --- |`,
    `| Apple reports delivery to our URL | ${report.appleDelivered ? "yes" : "no"} |`,
    `| Apple send attempts | ${report.attempts.map((a) => `${a.result} ${a.at ?? ""}`.trim()).join(", ") || "none"} |`,
    `| Notification UUID | ${report.notificationUuid ?? "none"} |`,
    `| Recorded in apple_notifications | ${report.recorded ? `yes, received ${report.receivedAt}, processed ${report.processedAt ?? "not yet"}` : "no"} |`,
    `| Elapsed | ${(report.elapsedMs / 1000).toFixed(1)} s |`,
    ...(report.note ? ["", `**Note:** ${report.note}`] : []),
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
