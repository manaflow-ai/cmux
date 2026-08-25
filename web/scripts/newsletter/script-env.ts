// Shared env plumbing for the newsletter CLI scripts.

// Default sender for newsletter drafts and test previews; matches the
// verified Resend domain used by the transactional founders welcome.
export const DEFAULT_NEWSLETTER_FROM = "Austin Wang <austin@manaflow.ai>";

export function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    // Do not echo secret/configuration key names into user-facing CLI output;
    // operators can consult NEWSLETTER.md for the required configuration.
    throw new Error("Newsletter configuration is incomplete.");
  }
  return value;
}

export function newsletterFrom(): string {
  return process.env.CMUX_NEWSLETTER_FROM_EMAIL?.trim() || DEFAULT_NEWSLETTER_FROM;
}
