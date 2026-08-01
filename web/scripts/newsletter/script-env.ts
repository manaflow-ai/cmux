// Shared env plumbing for the newsletter CLI scripts.

// Default sender for newsletter drafts and test previews; matches the
// verified Resend domain used by the transactional founders welcome.
export const DEFAULT_NEWSLETTER_FROM = "Austin Wang <austin@manaflow.ai>";

export function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required env var ${name}`);
  }
  return value;
}

export function newsletterFrom(): string {
  return process.env.CMUX_NEWSLETTER_FROM_EMAIL?.trim() || DEFAULT_NEWSLETTER_FROM;
}
