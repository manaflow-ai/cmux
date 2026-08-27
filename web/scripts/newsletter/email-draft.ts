// Create a Resend Broadcast DRAFT for human review. This script cannot send.
//
//   bun run email:draft --template product-update --audience users
//   bun run email:draft --template product-update --audience founders --subject "cmux update" --locale ja
//
// It renders the React Email template, creates the broadcast as a draft
// against the chosen segment (scoped to that segment's unsubscribe topic so
// per-topic opt-outs are honored), and prints the Resend dashboard URL. The
// actual send is a deliberate human click in the Resend dashboard after
// reviewing the draft there; no send capability exists in this repo's
// tooling, and unknown flags (for example --send) are rejected before any
// API call.
//
// Env: RESEND_API_KEY with "Full access" permission. Optional
// CMUX_NEWSLETTER_FROM_EMAIL overrides the sender.

import { renderTemplate } from "../../emails/render";
import { parseDraftArgs } from "../../services/newsletter/cli";
import { ResendClient } from "../../services/newsletter/resend-client";
import {
  FOUNDERS_SEGMENT_NAME,
  FOUNDERS_TOPIC,
  USERS_SEGMENT_NAME,
  USERS_TOPIC,
} from "../../services/newsletter/sync";

import { newsletterFrom, requiredEnv } from "./script-env";

const args = parseDraftArgs(process.argv.slice(2));
const segmentName =
  args.audience === "users" ? USERS_SEGMENT_NAME : FOUNDERS_SEGMENT_NAME;
const topicName =
  args.audience === "users" ? USERS_TOPIC.name : FOUNDERS_TOPIC.name;

const client = new ResendClient({ apiKey: requiredEnv("RESEND_API_KEY") });
const segment = await client.findSegmentByName(segmentName);
if (!segment) {
  throw new Error(
    "The selected newsletter audience is not provisioned. Run " +
      "`bun run newsletter:sync --apply` first.",
  );
}
const topic = await client.findTopicByName(topicName);
if (!topic) {
  throw new Error(
    "The selected newsletter preference lane is not provisioned. Run " +
      "`bun run newsletter:sync --apply` first.",
  );
}
// Same fail-closed gate as the sync: this tooling never subscribes contacts
// to topics, so drafting against an opt-out-by-default topic would suppress
// the broadcast for nearly the whole segment.
if (topic.defaultSubscription !== "opt_in") {
  throw new Error(
    "The selected newsletter preference lane is configured unsafely. " +
      "Recreate it with opt-in defaults before drafting a broadcast.",
  );
}

const rendered = await renderTemplate(args.template, {
  subject: args.subject,
  locale: args.locale,
});
const from = newsletterFrom();

const draft = await client.createBroadcastDraft({
  segmentId: segment.id,
  topicId: topic.id,
  from,
  subject: rendered.subject,
  html: rendered.html,
  name: `${args.template} (${new Date().toISOString().slice(0, 10)})`,
});

console.log(`Draft broadcast created for the ${args.audience} audience.`);
console.log(`Review and send it here: https://resend.com/broadcasts/${draft.id}`);
console.log(
  "This tooling never sends broadcasts; the send button in the dashboard is the only send path.",
);
console.log(
  "If the dashboard cannot send an API-created draft on your plan, duplicate " +
    "it in the dashboard editor and send the copy; do not add a send flag here.",
);
