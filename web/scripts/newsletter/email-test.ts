// Send ONE one-off preview email for inbox/mobile/dark-mode checking.
//
//   bun run email:test --template product-update
//   bun run email:test --template product-update --greeting-name Austin --locale ja
//
// The recipient is hardcoded to austin@manaflow.ai. Any other --to value is
// refused unless the explicit override flag
// --dangerously-email-someone-other-than-austin is also passed (see
// services/newsletter/cli.ts). This is a single transactional send, never a
// broadcast, so it cannot reach an audience.
//
// Merge tags ({{{contact.first_name|...}}}, {{{RESEND_UNSUBSCRIBE_URL}}})
// are only substituted by Resend for broadcast sends; in this preview the
// greeting defaults to the "there" fallback text and the unsubscribe link
// stays a literal token.
//
// Env: RESEND_API_KEY (a sending-only key is sufficient here). Optional
// CMUX_NEWSLETTER_FROM_EMAIL overrides the sender.

import { renderTemplate } from "../../emails/render";
import { parseTestSendArgs } from "../../services/newsletter/cli";
import { ResendClient } from "../../services/newsletter/resend-client";

import { newsletterFrom, requiredEnv } from "./script-env";

const args = parseTestSendArgs(process.argv.slice(2));

// One-off sends bypass merge-tag substitution, so give the greeting real
// text instead of a raw {{{FIRST_NAME|there}}} token in the preview.
const rendered = await renderTemplate(args.template, {
  greetingName: args.greetingName ?? "there",
  locale: args.locale,
});

const client = new ResendClient({ apiKey: requiredEnv("RESEND_API_KEY") });
const from = newsletterFrom();
await client.sendEmail({
  from,
  to: args.to,
  subject: `[TEST] ${rendered.subject}`,
  html: rendered.html,
});

// Do not echo the recipient address or provider-generated message id into
// terminal/CI logs; the command's success is all the operator needs here.
console.log("Test email sent successfully.");
console.log(
  "Note: the unsubscribe link is a literal merge token in test sends; it is " +
    "substituted per contact only when Resend sends a broadcast.",
);
