import { isCloudIntroEnabled, isCloudIntroRenewChargeEnabled } from "./cloudIntro";
import {
  buildCloudIntroStatement,
  buildCloudIntroStatementEmail,
  cloudIntroRenewalView,
  cloudIntroStatementLinks,
  type CloudIntroRenewalView,
  type CloudIntroStatementCopy,
  type CloudIntroStatementEmail,
  type CloudPassUsageReader,
} from "./cloudIntroStatements";
import type { CloudIntroStatementRow, CloudIntroStatementStore } from "./cloudIntroStatementStore";
import en from "../../messages/en.json";

/**
 * The cron step for the pass statements (RFD 0052). For each granted pass
 * with a statement due: read the buyer's usage, claim the statement under the
 * pass lock (which records it before anything is sent), then email it to the
 * buyer and record how the email went. A claimed statement is never sent
 * twice: a failed email stays `email_failed` and shows on Plan & billing.
 * With the pass flag off the step does nothing.
 */
export type CloudIntroStatementJobDependencies = {
  readonly env: Record<string, string | undefined>;
  readonly now: Date;
  readonly store: CloudIntroStatementStore;
  readonly readUsage: CloudPassUsageReader;
  /** The buyer's email address: the pass belongs to the buyer's own sign-in record. */
  readonly recipientEmail: (stackUserId: string) => Promise<string | null>;
  readonly sendEmail: (
    payload: CloudIntroStatementEmail,
    options: { idempotencyKey: string },
  ) => Promise<{ error: unknown | null }>;
  readonly fromEmail: string;
  readonly replyTo: string;
  /** The site origin for links in the email. */
  readonly origin: string;
  /** How the statement shows the buyer's Plus choice; null holds the statement. Defaults to cloudIntroRenewalView. */
  readonly renewalView?: (pass: CloudIntroStatementRow) => CloudIntroRenewalView | null;
};

export type CloudIntroStatementJobResult = {
  readonly skipped: boolean;
  readonly considered: number;
  readonly sent: number;
  readonly noEmail: number;
  readonly failed: number;
};

export const cloudIntroStatementCopy: CloudIntroStatementCopy = en.emails.cloudPassStatement;

export function cloudIntroStatementIdempotencyKey(checkoutSessionId: string, day: number): string {
  return `cmux-cloud-pass-statement/${checkoutSessionId}/${day}`;
}

export async function runCloudIntroStatements(
  deps: CloudIntroStatementJobDependencies,
): Promise<CloudIntroStatementJobResult> {
  if (!isCloudIntroEnabled(deps.env)) return { skipped: true, considered: 0, sent: 0, noEmail: 0, failed: 0 };
  const chargeEnabled = isCloudIntroRenewChargeEnabled(deps.env);
  const renewalView = deps.renewalView ??
    ((pass: CloudIntroStatementRow) => cloudIntroRenewalView(pass, chargeEnabled, deps.now));
  const candidates = await deps.store.listCandidates(deps.now);
  let sent = 0;
  let noEmail = 0;
  let failed = 0;
  for (const candidate of candidates) {
    try {
      const outcome = await statementForPass(candidate, deps, renewalView);
      if (outcome === "emailed") sent += 1;
      else if (outcome === "no_email") noEmail += 1;
      else if (outcome === "email_failed") failed += 1;
    } catch (error) {
      failed += 1;
      console.error("[billing] cmux Cloud pass statement failed", {
        checkoutSessionId: candidate.checkoutSessionId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return { skipped: false, considered: candidates.length, sent, noEmail, failed };
}

async function statementForPass(
  candidate: CloudIntroStatementRow,
  deps: CloudIntroStatementJobDependencies,
  renewalView: (pass: CloudIntroStatementRow) => CloudIntroRenewalView | null,
): Promise<"emailed" | "no_email" | "email_failed" | "none"> {
  if (!candidate.startedAt || !candidate.endsAt) return "none";
  // Read before the claim, outside the lock; the claim decides whether it is used.
  const usage = await deps.readUsage({
    stackUserId: candidate.stackUserId,
    from: candidate.startedAt,
    to: new Date(Math.min(deps.now.getTime(), candidate.endsAt.getTime())),
  });
  // The view is decided on the locked row, so a charge recorded a moment ago is what the statement says.
  const claim = await deps.store.claim(candidate.checkoutSessionId, deps.now, (pass, due) => {
    const renewal = renewalView(pass);
    return renewal ? buildCloudIntroStatement({ pass, day: due.day, usage, now: deps.now, renewal }) : null;
  });
  if (!claim) return "none";
  const to = await deps.recipientEmail(claim.pass.stackUserId).catch(() => null);
  if (!to) {
    await deps.store.markDelivery(claim.pass.checkoutSessionId, claim.day, "no_email");
    return "no_email";
  }
  const email = buildCloudIntroStatementEmail({
    from: deps.fromEmail,
    to,
    replyTo: deps.replyTo,
    checkoutSessionId: claim.pass.checkoutSessionId,
    statement: claim.statement,
    copy: cloudIntroStatementCopy,
    links: cloudIntroStatementLinks(deps.origin),
  });
  let delivered = false;
  try {
    const result = await deps.sendEmail(email, {
      idempotencyKey: cloudIntroStatementIdempotencyKey(claim.pass.checkoutSessionId, claim.day),
    });
    delivered = !result.error;
  } catch {
    delivered = false;
  }
  await deps.store.markDelivery(claim.pass.checkoutSessionId, claim.day, delivered ? "emailed" : "email_failed");
  return delivered ? "emailed" : "email_failed";
}
