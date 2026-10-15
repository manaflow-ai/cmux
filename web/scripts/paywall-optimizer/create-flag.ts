#!/usr/bin/env bun
// Creates the `ios-paywall-v1` PostHog flag from the seed definition. Run
// once, after the PR that adds it is merged and its migration is applied:
//
//   bun scripts/paywall-optimizer/create-flag.ts --print     # show the body
//   POSTHOG_PERSONAL_API_KEY=phx_... bun scripts/paywall-optimizer/create-flag.ts
//
// Every seeded payload is validated first; the script refuses to create a
// flag whose copy the server would not serve. It also refuses when the flag
// already exists, so it never overwrites live copy or traffic.

import { iosPaywallV1FlagDefinition, IOS_PAYWALL_V1_SEED, IOS_PAYWALL_EXPERIMENT } from "../../services/billing/paywall/iosPaywallV1";
import { POSTHOG_PROJECT_ID_DEFAULT } from "../../services/billing/paywall/runAll";
import { validateIosPaywallPayload } from "../../services/billing/paywall/validator";

const definition = iosPaywallV1FlagDefinition();
const errors = IOS_PAYWALL_V1_SEED.flatMap((variant) => {
  const result = validateIosPaywallPayload(variant.payload, IOS_PAYWALL_EXPERIMENT, variant.key);
  return result.ok ? [] : result.errors.map((error) => `${variant.key}: ${error}`);
});
if (errors.length > 0) {
  console.error(errors.join("\n"));
  process.exit(1);
}
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
const existing = await fetch(`${host}/api/projects/${project}/feature_flags/?search=${IOS_PAYWALL_EXPERIMENT}&limit=100`, { headers });
if (!existing.ok) {
  console.error(`Could not list flags: ${existing.status} ${(await existing.text()).slice(0, 300)}`);
  process.exit(1);
}
const found = ((await existing.json()) as { results?: { key: string; deleted?: boolean }[] }).results ?? [];
if (found.some((flag) => flag.key === IOS_PAYWALL_EXPERIMENT && !flag.deleted)) {
  console.error(`${IOS_PAYWALL_EXPERIMENT} already exists; edit it in PostHog or with the optimizer`);
  process.exit(1);
}
const response = await fetch(`${host}/api/projects/${project}/feature_flags/`, { method: "POST", headers, body: JSON.stringify(definition) });
console.log(response.status, (await response.text()).slice(0, 2000));
process.exit(response.ok ? 0 : 1);
