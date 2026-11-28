// Synthetic (probe) accounts in product analytics.
//
// The Cloud VM canary (.github/workflows/cloud-vm-canary.yml, every five
// minutes) and the manual smoke, dogfood, stress and startup-bench scripts
// under web/scripts/cloud-vm/ each mint a throwaway Stack user named
// `cmux-<prod|staging>-<smoke|stress|bench>+<suffix>@manaflow.dev`, create a
// machine, and destroy it within a minute. Those rows are real production
// traffic and stay in PostHog (they prove the create path works), but every
// product count must be able to exclude them, so their events carry
// `is_synthetic: true`.
//
// The address is the authoritative marker: only the team controls the
// manaflow.dev mailbox, and the scripts set the address server-side.

const SYNTHETIC_ACCOUNT_EMAIL = /^cmux-(?:prod|staging)-(?:smoke|stress|bench)\+[^@\s]*@manaflow\.dev$/i;

/** Whether a Stack primary email belongs to a probe account. */
export function isSyntheticAccountEmail(email: string | null | undefined): boolean {
  return typeof email === "string" && SYNTHETIC_ACCOUNT_EMAIL.test(email.trim());
}

// Ledger rows are mirrored after the response, sometimes outside the request
// that authenticated the user. Remember probe user ids seen by this instance
// so those rows are tagged too. Bounded: the canary mints one user per run.
const MAX_REMEMBERED_SYNTHETIC_USERS = 512;
const syntheticUserIds = new Set<string>();

/** Record that an authenticated user is a probe account. */
export function rememberSyntheticUser(userId: string): void {
  if (syntheticUserIds.has(userId)) return;
  if (syntheticUserIds.size >= MAX_REMEMBERED_SYNTHETIC_USERS) {
    const oldest = syntheticUserIds.values().next().value;
    if (oldest !== undefined) syntheticUserIds.delete(oldest);
  }
  syntheticUserIds.add(userId);
}

/** Whether this instance authenticated `userId` as a probe account. */
export function isRememberedSyntheticUser(userId: string | null | undefined): boolean {
  return typeof userId === "string" && syntheticUserIds.has(userId);
}
