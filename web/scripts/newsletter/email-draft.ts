// Create a Resend Broadcast DRAFT for human review. This script cannot send.
//
//   bun run email:draft --template product-update --audience users
//   bun run email:draft --template product-update --audience founders --subject "cmux update"
//
// It renders the React Email template, creates the broadcast as a draft
// against the chosen audience, and prints the Resend dashboard URL. The
// actual send to the audience is a deliberate human click in the Resend
// dashboard after reviewing the draft there; no send capability exists in
// this repo's tooling, and unknown flags (for example --send) are rejected
// before any API call.
//
// Env: RESEND_API_KEY with "Full access" permission. Optional
// CMUX_NEWSLETTER_FROM_EMAIL overrides the sender.

import { renderTemplate } from "../../emails/render";
import { parseDraftArgs } from "../../services/newsletter/cli";
import { ResendClient } from "../../services/newsletter/resend-client";
import {
  FOUNDERS_AUDIENCE_NAME,
  USERS_AUDIENCE_NAME,
} from "../../services/newsletter/sync";

const DEFAULT_FROM = "Austin Wang <austin@manaflow.ai>";

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var ${name}`);
  }
  return value;
}

const args = parseDraftArgs(process.argv.slice(2));
const audienceName =
  args.audience === "users" ? USERS_AUDIENCE_NAME : FOUNDERS_AUDIENCE_NAME;

const client = new ResendClient({ apiKey: requiredEnv("RESEND_API_KEY") });
const audience = await client.findAudienceByName(audienceName);
if (!audience) {
  throw new Error(
    `Audience "${audienceName}" does not exist in Resend. Run ` +
      "`bun run newsletter:sync --apply` first to create and populate it.",
  );
}

const rendered = await renderTemplate(args.template, {
  subject: args.subject,
});
const from = process.env.CMUX_NEWSLETTER_FROM_EMAIL?.trim() || DEFAULT_FROM;

const draft = await client.createBroadcastDraft({
  audienceId: audience.id,
  from,
  subject: rendered.subject,
  html: rendered.html,
  name: `${args.template} (${new Date().toISOString().slice(0, 10)})`,
});

console.log(`Draft broadcast created for audience "${audienceName}".`);
console.log(`Review and send it here: https://resend.com/broadcasts/${draft.id}`);
console.log(
  "This tooling never sends broadcasts; the send button in the dashboard is the only send path.",
);
