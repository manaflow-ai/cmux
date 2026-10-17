#!/usr/bin/env bun
// Creates the `web-pricing-v1` PostHog flag from webPricingV1.ts. Run once,
// after the PR that adds it is merged:
//
//   bun scripts/pricing-experiment/create-flag.ts --print     # show the body
//   POSTHOG_PERSONAL_API_KEY=phx_... bun scripts/pricing-experiment/create-flag.ts
//
// It refuses when any variant's copy fails the shared validator, and when
// the flag already exists, so it never overwrites a live split.

import { POSTHOG_PROJECT_ID_DEFAULT } from "../../services/billing/paywall/runAll";
import {
  WEB_PRICING_EXPERIMENT,
  WEB_PRICING_V1_VARIANTS,
  webPricingV1FlagDefinition,
  webPricingVariantErrors,
} from "../../services/billing/pricingExperiment/webPricingV1";

const errors = WEB_PRICING_V1_VARIANTS.flatMap((variant) =>
  webPricingVariantErrors(variant).map((error) => `${variant.key}: ${error}`));
if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
const definition = webPricingV1FlagDefinition();
if (process.argv.includes("--print")) {
  console.log(JSON.stringify(definition, null, 2));
  process.exit(0);
}
const key = process.env.POSTHOG_PERSONAL_API_KEY?.trim();
if (!key) {
  console.error("POSTHOG_PERSONAL_API_KEY is required");
  process.exit(2);
}
const host = (process.env.POSTHOG_API_HOST?.trim() || "https://us.posthog.com").replace(/\/$/, "");
const project = process.env.POSTHOG_PROJECT_ID?.trim() || POSTHOG_PROJECT_ID_DEFAULT;
const headers = { authorization: `Bearer ${key}`, "content-type": "application/json" };
const existing = await fetch(`${host}/api/projects/${project}/feature_flags/?search=${WEB_PRICING_EXPERIMENT}`, { headers });
const found = ((await existing.json()) as { results?: { key: string; deleted?: boolean }[] }).results ?? [];
if (found.some((flag) => flag.key === WEB_PRICING_EXPERIMENT && !flag.deleted)) {
  console.error(`${WEB_PRICING_EXPERIMENT} already exists; edit it in PostHog or with the optimizer`);
  process.exit(1);
}
const response = await fetch(`${host}/api/projects/${project}/feature_flags/`, { method: "POST", headers, body: JSON.stringify(definition) });
console.log(response.status, (await response.text()).slice(0, 2000));
process.exit(response.ok ? 0 : 1);
