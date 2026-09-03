// Tells the people who can fix it when a coderouter account stops working:
// a Claude account marked `broken` (credential rejected repeatedly) or a
// Codex/OpenCode subscription whose sign-in can no longer be refreshed
// (`expired` or `broken`). One email per account, ever: each account carries
// a `broken_notified_at` that is set when its notice has been sent, and the
// job runs on a schedule so accounts that break within the same window share
// one email per recipient. Nothing here retries a send that succeeded.
import { and, inArray, isNull } from "drizzle-orm";
import { Resend } from "resend";
import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { coderouterAccounts } from "../../db/schema";
import {
  listBrokenClaudeAccounts,
  markClaudeAccountsNotified,
  type ClaudeAccountRow,
} from "./claudeUpstream";
import { addCoderouterBreadcrumb, reportCoderouterFailure } from "./observability";

export const DEFAULT_CODEROUTER_FROM_EMAIL = "coderouter@cmux.com";
export const CODEROUTER_SUPPORT_EMAIL = "support@cmux.com";
const DASHBOARD_ORIGIN = "https://cmux.com";
/** Recipients per email and accounts per run are bounded so one bad batch cannot fan out. */
const MAX_RECIPIENTS_PER_ACCOUNT = 25;
const MAX_ACCOUNTS_PER_RUN = 200;

export type BrokenAccountNotice = {
  readonly source: "claude" | "subscription";
  readonly accountId: string;
  readonly teamId: string;
  /** `claude`, `anthropic-key`, `bedrock`, `codex`, `opencode`. */
  readonly kind: string;
  readonly label: string;
  /** Masked identifier for Claude accounts; empty for subscriptions. */
  readonly identifier: string;
  readonly failureCode: string;
  readonly brokenAt: Date | null;
  /** Stack user id of whoever added it, when the store records that. */
  readonly createdBy: string | null;
};

export type Recipient = { readonly email: string; readonly name: string | null };

export type AccountHealthEmail = {
  readonly from: string;
  readonly to: string;
  readonly replyTo: string;
  readonly subject: string;
  readonly text: string;
  readonly html: string;
};

export type AccountHealthDependencies = {
  readonly brokenClaudeAccounts: () => Promise<readonly BrokenAccountNotice[]>;
  readonly brokenSubscriptionAccounts: () => Promise<readonly BrokenAccountNotice[]>;
  readonly markNotified: (notices: readonly BrokenAccountNotice[], at: Date) => Promise<void>;
  /** Who to tell about a team's accounts; the creator when known, else the team. */
  readonly recipients: (notice: BrokenAccountNotice) => Promise<readonly Recipient[]>;
  readonly teamName: (teamId: string) => Promise<string | null>;
  readonly send: (email: AccountHealthEmail) => Promise<void>;
  readonly fromEmail: () => string;
  readonly now: () => Date;
};

export type AccountHealthRunResult = {
  readonly accounts: number;
  readonly emails: number;
  readonly recipients: number;
  readonly withoutRecipient: number;
  readonly failures: number;
};

export async function runAccountHealthNotifications(
  dependencies: AccountHealthDependencies = defaultDependencies(),
): Promise<AccountHealthRunResult> {
  const at = dependencies.now();
  const notices = [
    ...(await dependencies.brokenClaudeAccounts()),
    ...(await dependencies.brokenSubscriptionAccounts()),
  ].slice(0, MAX_ACCOUNTS_PER_RUN);
  if (notices.length === 0) {
    return { accounts: 0, emails: 0, recipients: 0, withoutRecipient: 0, failures: 0 };
  }

  // Batch: one email per recipient listing every account of theirs that broke.
  const byRecipient = new Map<string, { recipient: Recipient; notices: BrokenAccountNotice[] }>();
  const teamNames = new Map<string, string | null>();
  let withoutRecipient = 0;
  const unaddressed: BrokenAccountNotice[] = [];
  for (const notice of notices) {
    if (!teamNames.has(notice.teamId)) {
      teamNames.set(notice.teamId, await dependencies.teamName(notice.teamId).catch(() => null));
    }
    const recipients = (await dependencies.recipients(notice).catch(() => [])).slice(0, MAX_RECIPIENTS_PER_ACCOUNT);
    if (recipients.length === 0) {
      withoutRecipient += 1;
      unaddressed.push(notice);
      continue;
    }
    for (const recipient of recipients) {
      const key = recipient.email.toLowerCase();
      const entry = byRecipient.get(key) ?? { recipient, notices: [] };
      entry.notices.push(notice);
      byRecipient.set(key, entry);
    }
  }

  let emails = 0;
  let failures = 0;
  const notified = new Set<string>();
  for (const { recipient, notices: mine } of byRecipient.values()) {
    const email = buildAccountHealthEmail({
      from: dependencies.fromEmail(),
      recipient,
      notices: mine,
      teamNames,
    });
    try {
      await dependencies.send(email);
      emails += 1;
      for (const notice of mine) notified.add(`${notice.source}:${notice.accountId}`);
    } catch (error) {
      failures += 1;
      reportCoderouterFailure("account_health_email", error, { recipients: 1, accounts: mine.length });
    }
  }
  // Accounts with nobody to tell are marked as well: the state is visible on
  // the dashboard and in the CLI, and retrying every run would never help.
  const done = notices.filter((notice) => notified.has(`${notice.source}:${notice.accountId}`)).concat(unaddressed);
  if (done.length > 0) await dependencies.markNotified(done, at);
  addCoderouterBreadcrumb("account", "Account health notifications sent", {
    accounts: notices.length,
    emails,
    recipients: byRecipient.size,
    without_recipient: withoutRecipient,
    failures,
  });
  return { accounts: notices.length, emails, recipients: byRecipient.size, withoutRecipient, failures };
}

// Email copy.

export function buildAccountHealthEmail(input: {
  readonly from: string;
  readonly recipient: Recipient;
  readonly notices: readonly BrokenAccountNotice[];
  readonly teamNames: ReadonlyMap<string, string | null>;
}): AccountHealthEmail {
  const teams = [...new Set(input.notices.map((notice) => notice.teamId))];
  const teamLabel = teams.length === 1
    ? (input.teamNames.get(teams[0]!) ?? "your team")
    : `${teams.length} of your teams`;
  const count = input.notices.length;
  const subject = count === 1
    ? `Action needed: a coderouter account stopped working in ${teamLabel}`
    : `Action needed: ${count} coderouter accounts stopped working in ${teamLabel}`;
  const greeting = input.recipient.name ? `Hi ${firstName(input.recipient.name)},` : "Hi,";

  const intro = count === 1
    ? "coderouter can no longer use one of the accounts your team routes Claude Code and Codex through. Requests from your Cloud machines that were pinned to it have moved to your other accounts; if it was the only one of its kind, those requests fail until you replace it."
    : `coderouter can no longer use ${count} of the accounts your team routes Claude Code and Codex through. Requests from your Cloud machines that were pinned to them have moved to your other accounts; where no other account of that kind exists, those requests fail until you replace them.`;

  const sections = input.notices.map((notice) => noticeSection(notice, input.teamNames.get(notice.teamId) ?? null));
  const dashboardLinks = teams.map((teamId) => `${DASHBOARD_ORIGIN}/dashboard/coderouter?team=${encodeURIComponent(teamId)}`);

  const textParts: string[] = [
    greeting,
    "",
    intro,
    "",
    "WHAT STOPPED WORKING",
    ...sections.flatMap((section) => ["", `- ${section.headline}`, `  Why: ${section.why}`, `  Fix: ${section.fix.join(" then ")}`]),
    "",
    "HOW TO FIX IT",
    "1. Add a fresh credential from any machine where you are signed in to cmux:",
    ...uniqueFixCommands(input.notices).map((command) => `     ${command}`),
    "2. Remove the broken account so nothing is routed to it again:",
    "     cmux coderouter accounts remove <id>   (ids are in the list above, or run: cmux coderouter accounts)",
    `3. Or do both on the dashboard: ${dashboardLinks.join(" ")}`,
    "",
    "WHY YOU GOT THIS EMAIL",
    `You added, or are a member of the team that owns, these accounts (${teamLabel}). We send exactly one email per account: you will not hear about these accounts again, and other accounts keep working as before.`,
    "",
    `Questions: reply to this email or write to ${CODEROUTER_SUPPORT_EMAIL}.`,
    "",
    "cmux",
  ];

  const htmlParts: string[] = [
    `<p>${escapeHtml(greeting)}</p>`,
    `<p>${escapeHtml(intro)}</p>`,
    "<h3>What stopped working</h3>",
    "<ul>",
    ...sections.map((section) =>
      `<li><strong>${escapeHtml(section.headline)}</strong><br>${escapeHtml(section.why)}<br><em>Fix:</em> ${section.fix.map((step) => `<code>${escapeHtml(step)}</code>`).join(" then ")}</li>`),
    "</ul>",
    "<h3>How to fix it</h3>",
    "<ol>",
    `<li>Add a fresh credential from any machine where you are signed in to cmux:<br>${uniqueFixCommands(input.notices).map((command) => `<code>${escapeHtml(command)}</code>`).join("<br>")}</li>`,
    `<li>Remove the broken account so nothing is routed to it again: <code>cmux coderouter accounts remove &lt;id&gt;</code> (ids are in the list above, or run <code>cmux coderouter accounts</code>).</li>`,
    `<li>Or do both on the dashboard: ${dashboardLinks.map((link) => `<a href="${escapeHtml(link)}">${escapeHtml(link)}</a>`).join(" ")}</li>`,
    "</ol>",
    "<h3>Why you got this email</h3>",
    `<p>${escapeHtml(`You added, or are a member of the team that owns, these accounts (${teamLabel}). We send exactly one email per account: you will not hear about these accounts again, and other accounts keep working as before.`)}</p>`,
    `<p>Questions: reply to this email or write to <a href="mailto:${CODEROUTER_SUPPORT_EMAIL}">${CODEROUTER_SUPPORT_EMAIL}</a>.</p>`,
    "<p>cmux</p>",
  ];

  return {
    from: `cmux coderouter <${input.from}>`,
    to: input.recipient.email,
    replyTo: CODEROUTER_SUPPORT_EMAIL,
    subject,
    text: textParts.join("\n"),
    html: htmlParts.join("\n"),
  };
}

type NoticeSection = { readonly headline: string; readonly why: string; readonly fix: readonly string[] };

/** Per-kind explanation of what happened and the exact repair, in the user's terms. */
export function noticeSection(notice: BrokenAccountNotice, teamName: string | null): NoticeSection {
  const name = notice.label && notice.identifier
    ? `${notice.identifier} (${notice.label})`
    : notice.label || notice.identifier || notice.accountId.slice(0, 8);
  const when = notice.brokenAt ? ` on ${notice.brokenAt.toISOString().replace("T", " ").slice(0, 16)} UTC` : "";
  const team = teamName ? ` in ${teamName}` : "";
  const id = notice.accountId.slice(0, 8);
  const removeStep = `cmux coderouter accounts remove ${id}`;
  switch (notice.kind) {
    case "claude":
      return {
        headline: `Claude Code token ${name}${team}, id ${id}`,
        why: `Anthropic rejected this token three times in a row (${notice.failureCode})${when}. Tokens from \`claude setup-token\` stop working when they expire (about a year after creation), when you sign out of Claude Code on the machine that created them, or when they are revoked at claude.ai.`,
        fix: ["claude setup-token", `cmux coderouter accounts add claude --label ${shellWord(notice.label || "work")}`, removeStep],
      };
    case "anthropic-key":
      return {
        headline: `Anthropic API key ${name}${team}, id ${id}`,
        why: `Anthropic rejected this key three times in a row (${notice.failureCode})${when}. Keys stop working when they are deleted or rotated in the Anthropic Console, or when the organization's billing is suspended.`,
        fix: [`cmux coderouter accounts add anthropic-key --label ${shellWord(notice.label || "work")}`, removeStep],
      };
    case "bedrock":
      return {
        headline: `Amazon Bedrock credentials ${name}${team}, id ${id}`,
        why: `AWS rejected these credentials three times in a row (${notice.failureCode})${when}. Access keys stop working when they are deactivated or deleted in IAM, and temporary session credentials expire on their own.`,
        fix: [`cmux coderouter accounts add bedrock --region <region> --label ${shellWord(notice.label || "bedrock")}`, removeStep],
      };
    case "codex":
    case "opencode":
      return {
        headline: `${notice.kind === "codex" ? "ChatGPT Codex" : "OpenCode Go"} subscription ${name}${team}, id ${id}`,
        why: `The sign-in for this subscription could not be renewed (${notice.failureCode})${when}. This happens when the account signed out everywhere, changed its password, lost its subscription, or the same sign-in was reused from another tool.`,
        fix: [`cmux coderouter accounts add ${notice.kind}`, removeStep],
      };
    default:
      return {
        headline: `${notice.kind} account ${name}${team}, id ${id}`,
        why: `The upstream rejected this credential (${notice.failureCode})${when}.`,
        fix: [`cmux coderouter accounts add ${notice.kind}`, removeStep],
      };
  }
}

function uniqueFixCommands(notices: readonly BrokenAccountNotice[]): string[] {
  const commands = new Set<string>();
  for (const notice of notices) {
    switch (notice.kind) {
      case "claude":
        commands.add("claude setup-token && cmux coderouter accounts add claude");
        break;
      case "anthropic-key":
        commands.add("ANTHROPIC_API_KEY=<new key> cmux coderouter accounts add anthropic-key");
        break;
      case "bedrock":
        commands.add("cmux coderouter accounts add bedrock --region <region>   (reads AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)");
        break;
      default:
        commands.add(`cmux coderouter accounts add ${notice.kind}`);
    }
  }
  return [...commands];
}

function shellWord(value: string): string {
  return /^[A-Za-z0-9_.@-]+$/.test(value) ? value : `'${value.replaceAll("'", "'\\''")}'`;
}

function firstName(value: string): string {
  return value.trim().split(/\s+/)[0] ?? value;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

// Default wiring.

export function noticeFromClaudeRow(row: ClaudeAccountRow): BrokenAccountNotice {
  return {
    source: "claude",
    accountId: row.id,
    teamId: row.teamId,
    kind: row.kind === "anthropic_oauth" ? "claude" : row.kind === "anthropic_api_key" ? "anthropic-key" : row.kind,
    label: row.label,
    identifier: row.identifier,
    failureCode: row.lastFailureCode ?? "invalid_credential",
    brokenAt: row.brokenAt,
    createdBy: row.createdBy,
  };
}

async function brokenSubscriptionRows(): Promise<readonly BrokenAccountNotice[]> {
  const rows = await cloudDb()
    .select({
      id: coderouterAccounts.id,
      teamId: coderouterAccounts.teamId,
      provider: coderouterAccounts.provider,
      label: coderouterAccounts.label,
      lastFailureCode: coderouterAccounts.lastFailureCode,
      updatedAt: coderouterAccounts.updatedAt,
    })
    .from(coderouterAccounts)
    .where(and(inArray(coderouterAccounts.state, ["expired", "broken"]), isNull(coderouterAccounts.brokenNotifiedAt)))
    .limit(MAX_ACCOUNTS_PER_RUN);
  return rows.map((row) => ({
    source: "subscription" as const,
    accountId: row.id,
    teamId: row.teamId,
    kind: row.provider === "opencode-go" ? "opencode" : row.provider,
    label: row.label,
    identifier: "",
    failureCode: row.lastFailureCode ?? "refresh_failed",
    brokenAt: row.updatedAt,
    createdBy: null,
  }));
}

async function markSubscriptionsNotified(ids: readonly string[], at: Date): Promise<void> {
  if (ids.length === 0) return;
  await cloudDb()
    .update(coderouterAccounts)
    .set({ brokenNotifiedAt: at })
    .where(and(inArray(coderouterAccounts.id, [...ids]), isNull(coderouterAccounts.brokenNotifiedAt)));
}

/**
 * Stack lookups: the creator's email when the store recorded one, else every
 * member of the team. Stack is loaded lazily so the copy builder stays
 * importable in tests without auth configuration.
 */
async function stackRecipients(notice: BrokenAccountNotice): Promise<readonly Recipient[]> {
  const { getStackServerApp } = await import("../../app/lib/stack");
  const app = getStackServerApp();
  if (notice.createdBy) {
    const user = await app.getUser(notice.createdBy).catch(() => null);
    if (user?.primaryEmail) return [{ email: user.primaryEmail, name: user.displayName ?? null }];
  }
  const team = await app.getTeam(notice.teamId).catch(() => null);
  if (!team) {
    // Personal organizations use the user id as the team id.
    const user = await app.getUser(notice.teamId).catch(() => null);
    return user?.primaryEmail ? [{ email: user.primaryEmail, name: user.displayName ?? null }] : [];
  }
  const members = await team.listUsers().catch(() => []);
  return members
    .map((member) => ({ email: member.primaryEmail ?? "", name: member.displayName ?? null }))
    .filter((member) => member.email.length > 0);
}

async function stackTeamName(teamId: string): Promise<string | null> {
  const { getStackServerApp } = await import("../../app/lib/stack");
  const team = await getStackServerApp().getTeam(teamId).catch(() => null);
  return team?.displayName ?? null;
}

export function defaultDependencies(): AccountHealthDependencies {
  return {
    brokenClaudeAccounts: async () => (await listBrokenClaudeAccounts()).map(noticeFromClaudeRow),
    brokenSubscriptionAccounts: brokenSubscriptionRows,
    markNotified: async (notices, at) => {
      await markClaudeAccountsNotified(notices.filter((notice) => notice.source === "claude").map((notice) => notice.accountId));
      await markSubscriptionsNotified(notices.filter((notice) => notice.source === "subscription").map((notice) => notice.accountId), at);
    },
    recipients: stackRecipients,
    teamName: stackTeamName,
    send: async (email) => {
      const resend = new Resend(env.RESEND_API_KEY);
      const result = await resend.emails.send({
        from: email.from,
        to: [email.to],
        replyTo: email.replyTo,
        subject: email.subject,
        text: email.text,
        html: email.html,
      });
      if (result.error) throw new Error(`resend: ${result.error.message}`);
    },
    fromEmail: () => process.env.CMUX_CODEROUTER_FROM_EMAIL?.trim() || DEFAULT_CODEROUTER_FROM_EMAIL,
    now: () => new Date(),
  };
}
