import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(
  resolve(webRoot, "scripts/stripe/provision-catalog.sh"),
  "utf8",
);

test("keeps Stripe credentials and webhook secrets out of predictable process and file paths", () => {
  expect(source).not.toContain('-u "${STRIPE_PROVISION_KEY}:"');
  expect(source).toContain("--header @-");
  expect(source).toContain("mktemp");
  expect(source).not.toContain('WEBHOOK_SECRET_FILE="/tmp/.cmux-live-whsec"');
});

test("validates catalog identity, cadence, and unique webhook ownership", () => {
  expect(source).toContain("product_matches_catalog_identity");
  expect(source).toContain("recurring.interval_count");
  expect(source).toContain("webhook_ids");
  expect(source).toContain("Multiple enabled webhook endpoints");
});
