// Tells the people who can fix it when a coderouter account stops working:
// a Claude account marked `broken` (credential rejected repeatedly) or a
// Codex/OpenCode subscription whose sign-in can no longer be refreshed
// (`expired` or `broken`). One email per account, ever: each account carries
// a `broken_notified_at` that is set when its notice has been sent, and the
// job runs on a schedule so accounts that break within the same window share
// one email per recipient. Nothing here retries a send that succeeded.
// Stack does not currently guarantee a saved locale on every user. We use it
// when present and fall back to English; the release localization pass owns
// translations beyond the maintained English and Japanese catalogs.
import { createHash } from "node:crypto";
import { and, inArray, isNull } from "drizzle-orm";
import { Resend } from "resend";
import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { coderouterAccounts } from "../../db/schema";
import englishMessages from "../../messages/en.json";
import { loadMessages } from "../../i18n/messages";
import { routing, type Locale } from "../../i18n/routing";
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

export type Recipient = { readonly email: string; readonly name: string | null; readonly locale?: Locale };

export type AccountHealthEmail = {
  /** Stable across retries of the same recipient/account batch. */
  readonly idempotencyKey: string;
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

type AccountHealthCopy = {
  readonly subjectOne: string;
  readonly subjectMany: string;
  readonly yourTeam: string;
  readonly manyTeams: string;
  readonly teamSuffix: string;
  readonly whenSuffix: string;
  readonly greetingNamed: string;
  readonly greeting: string;
  readonly introOne: string;
  readonly introMany: string;
  readonly whatStoppedWorking: string;
  readonly whyPrefix: string;
  readonly fixPrefix: string;
  readonly thenSeparator: string;
  readonly howToFix: string;
  readonly addCredentialInstruction: string;
  readonly removeCredentialInstruction: string;
  readonly removeCommand: string;
  readonly removeCommandHint: string;
  readonly dashboardInstruction: string;
  readonly whyYouGot: string;
  readonly whyBody: string;
  readonly questions: string;
  readonly signature: string;
  readonly claudeHeadline: string;
  readonly claudeWhy: string;
  readonly anthropicKeyHeadline: string;
  readonly anthropicKeyWhy: string;
  readonly bedrockHeadline: string;
  readonly bedrockWhy: string;
  readonly codexHeadline: string;
  readonly opencodeHeadline: string;
  readonly subscriptionWhy: string;
  readonly genericHeadline: string;
  readonly genericWhy: string;
  readonly bedrockEnvironmentHint: string;
};

const ACCOUNT_HEALTH_COPY_KEYS = [
  "subjectOne", "subjectMany", "yourTeam", "manyTeams", "teamSuffix", "whenSuffix",
  "greetingNamed", "greeting", "introOne", "introMany",
  "whatStoppedWorking", "whyPrefix", "fixPrefix", "thenSeparator", "howToFix", "addCredentialInstruction",
  "removeCredentialInstruction", "removeCommand", "removeCommandHint", "dashboardInstruction", "whyYouGot", "whyBody",
  "questions", "signature", "claudeHeadline", "claudeWhy", "anthropicKeyHeadline", "anthropicKeyWhy",
  "bedrockHeadline", "bedrockWhy", "codexHeadline", "opencodeHeadline", "subscriptionWhy",
  "genericHeadline", "genericWhy", "bedrockEnvironmentHint",
] as const;

function readAccountHealthCopy(value: unknown): Partial<AccountHealthCopy> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const record = value as Record<string, unknown>;
  const copy: Record<string, string> = {};
  for (const key of ACCOUNT_HEALTH_COPY_KEYS) {
    if (typeof record[key] === "string") copy[key] = record[key];
  }
  return copy as Partial<AccountHealthCopy>;
}

const ENGLISH_ACCOUNT_HEALTH_COPY = readAccountHealthCopy(
  (englishMessages as unknown as { readonly emails?: { readonly coderouterAccountHealth?: unknown } }).emails?.coderouterAccountHealth,
) as AccountHealthCopy;

async function accountHealthCopy(locale: Locale | undefined): Promise<AccountHealthCopy> {
  if (!locale || locale === "en") return ENGLISH_ACCOUNT_HEALTH_COPY;
  try {
    const messages = await loadMessages(locale);
    const localized = readAccountHealthCopy(
      (messages as unknown as { readonly emails?: { readonly coderouterAccountHealth?: unknown } }).emails?.coderouterAccountHealth,
    );
    return { ...ENGLISH_ACCOUNT_HEALTH_COPY, ...localized } as AccountHealthCopy;
  } catch {
    return ENGLISH_ACCOUNT_HEALTH_COPY;
  }
}

function renderTemplate(template: string, values: Readonly<Record<string, string | number>>): string {
  return template.replace(/\{([A-Za-z][A-Za-z0-9]*)\}/g, (_, key: string) => String(values[key] ?? ""));
}

export async function runAccountHealthNotifications(
  dependencies: AccountHealthDependencies = defaultDependencies(),
): Promise<AccountHealthRunResult> {
  const at = dependencies.now();
  const notices = selectAccountHealthNotices(
    await dependencies.brokenClaudeAccounts(),
    await dependencies.brokenSubscriptionAccounts(),
  );
  if (notices.length === 0) {
    return { accounts: 0, emails: 0, recipients: 0, withoutRecipient: 0, failures: 0 };
  }

  // Batch: one email per recipient listing every account of theirs that broke.
  const byRecipient = new Map<string, { recipient: Recipient; notices: BrokenAccountNotice[]; noticeKeys: Set<string> }>();
  const expectedRecipients = new Map<string, Set<string>>();
  const teamNames = new Map<string, string | null>();
  const teamRecipients = new Map<string, readonly Recipient[]>();
  let withoutRecipient = 0;
  const unaddressed: BrokenAccountNotice[] = [];
  for (const notice of notices) {
    const noticeKey = accountHealthNoticeKey(notice);
    if (!teamNames.has(notice.teamId)) {
      teamNames.set(notice.teamId, await dependencies.teamName(notice.teamId).catch(() => null));
    }
    let recipients: readonly Recipient[];
    if (!notice.createdBy && teamRecipients.has(notice.teamId)) {
      recipients = teamRecipients.get(notice.teamId)!;
    } else {
      recipients = (await dependencies.recipients(notice).catch(() => [])).slice(0, MAX_RECIPIENTS_PER_ACCOUNT);
      if (!notice.createdBy) teamRecipients.set(notice.teamId, recipients);
    }
    if (recipients.length === 0) {
      withoutRecipient += 1;
      unaddressed.push(notice);
      continue;
    }
    for (const recipient of recipients) {
      const key = recipient.email.trim().toLowerCase();
      if (!key) continue;
      const expected = expectedRecipients.get(noticeKey) ?? new Set<string>();
      expected.add(key);
      expectedRecipients.set(noticeKey, expected);
      const entry = byRecipient.get(key) ?? { recipient, notices: [], noticeKeys: new Set<string>() };
      if (!entry.noticeKeys.has(noticeKey)) {
        entry.noticeKeys.add(noticeKey);
        entry.notices.push(notice);
      }
      byRecipient.set(key, entry);
    }
    if (!expectedRecipients.has(noticeKey)) {
      withoutRecipient += 1;
      unaddressed.push(notice);
    }
  }

  let emails = 0;
  let failures = 0;
  const successfulRecipients = new Map<string, Set<string>>();
  for (const [recipientKey, { recipient, notices: mine }] of byRecipient) {
    try {
      const email = await buildAccountHealthEmail({
        from: dependencies.fromEmail(),
        recipient,
        notices: mine,
        teamNames,
      });
      await dependencies.send(email);
      emails += 1;
      for (const notice of mine) {
        const noticeKey = accountHealthNoticeKey(notice);
        const successful = successfulRecipients.get(noticeKey) ?? new Set<string>();
        successful.add(recipientKey);
        successfulRecipients.set(noticeKey, successful);
      }
    } catch (error) {
      failures += 1;
      reportCoderouterFailure("account_health_email", error, { recipients: 1, accounts: mine.length });
    }
  }
  // Accounts with nobody to tell are marked as well: the state is visible on
  // the dashboard and in the CLI, and retrying every run would never help.
  // When a team notice has several recipients, keep it pending until every
  // distinct recipient accepts it. Resend's stable idempotency key makes the
  // successful deliveries safe to retry on the next run.
  const unaddressedKeys = new Set(unaddressed.map(accountHealthNoticeKey));
  const done = notices.filter((notice) => {
    const noticeKey = accountHealthNoticeKey(notice);
    if (unaddressedKeys.has(noticeKey)) return true;
    const expected = expectedRecipients.get(noticeKey);
    const successful = successfulRecipients.get(noticeKey);
    return !!expected && !!successful && [...expected].every((key) => successful.has(key));
  }).sort((left, right) => {
    // Keep the historical Claude-then-subscription order for the persistence
    // update, even though selection is interleaved for fairness.
    return left.source === right.source ? 0 : left.source === "claude" ? -1 : 1;
  });
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

/**
 * Selects both account sources fairly so one large Claude batch cannot starve
 * subscriptions. Each source keeps its query order. The subscription reserve
 * is taken first, and any unused reserve goes back to Claude, so small queues
 * keep the original Claude-then-subscription ordering.
 */
export function selectAccountHealthNotices(
  claude: readonly BrokenAccountNotice[],
  subscriptions: readonly BrokenAccountNotice[],
  limit = MAX_ACCOUNTS_PER_RUN,
): BrokenAccountNotice[] {
  if (limit <= 0) return [];
  const subscriptionReserve = subscriptions.length > 0
    ? Math.min(subscriptions.length, Math.max(1, Math.floor(limit / 2)))
    : 0;
  const claudeCount = Math.min(claude.length, limit - subscriptionReserve);
  const unusedReserve = limit - claudeCount - subscriptionReserve;
  const subscriptionCount = Math.min(subscriptions.length, subscriptionReserve + unusedReserve);
  return [
    ...claude.slice(0, claudeCount),
    ...subscriptions.slice(0, subscriptionCount),
  ];
}

function accountHealthNoticeKey(notice: BrokenAccountNotice): string {
  return `${notice.source}:${notice.accountId}`;
}

// Email copy.

export async function buildAccountHealthEmail(input: {
  readonly from: string;
  readonly recipient: Recipient;
  readonly notices: readonly BrokenAccountNotice[];
  readonly teamNames: ReadonlyMap<string, string | null>;
}): Promise<AccountHealthEmail> {
  const copy = await accountHealthCopy(input.recipient.locale);
  const teams = [...new Set(input.notices.map((notice) => notice.teamId))];
  const teamLabel = teams.length === 1
    ? (input.teamNames.get(teams[0]!) ?? copy.yourTeam)
    : renderTemplate(copy.manyTeams, { count: teams.length });
  const count = input.notices.length;
  const subject = renderTemplate(count === 1 ? copy.subjectOne : copy.subjectMany, {
    count,
    team: teamLabel,
  });
  const greeting = input.recipient.name
    ? renderTemplate(copy.greetingNamed, { name: firstName(input.recipient.name) })
    : copy.greeting;

  const intro = renderTemplate(count === 1 ? copy.introOne : copy.introMany, { count });

  const sections = input.notices.map((notice) => noticeSectionWithCopy(notice, input.teamNames.get(notice.teamId) ?? null, copy));
  const dashboardLinks = teams.map((teamId) => `${DASHBOARD_ORIGIN}/dashboard/coderouter?team=${encodeURIComponent(teamId)}`);
  const dashboardLinkText = dashboardLinks.join(" ");
  const whyBody = renderTemplate(copy.whyBody, { team: teamLabel });
  const questions = renderTemplate(copy.questions, { email: CODEROUTER_SUPPORT_EMAIL });
  const fixCommands = uniqueFixCommands(input.notices, copy);

  const textParts: string[] = [
    greeting,
    "",
    intro,
    "",
    copy.whatStoppedWorking,
    ...sections.flatMap((section) => ["", `- ${section.headline}`, `  ${copy.whyPrefix}: ${section.why}`, `  ${copy.fixPrefix}: ${section.fix.join(copy.thenSeparator)}`]),
    "",
    copy.howToFix,
    copy.addCredentialInstruction,
    ...fixCommands.map((command) => `     ${command}`),
    copy.removeCredentialInstruction,
    `     ${copy.removeCommand}   ${copy.removeCommandHint}`,
    renderTemplate(copy.dashboardInstruction, { links: dashboardLinkText }),
    "",
    copy.whyYouGot,
    whyBody,
    "",
    questions,
    "",
    copy.signature,
  ];

  const htmlParts: string[] = [
    `<p>${escapeHtml(greeting)}</p>`,
    `<p>${escapeHtml(intro)}</p>`,
    `<h3>${escapeHtml(copy.whatStoppedWorking)}</h3>`,
    "<ul>",
    ...sections.map((section) =>
      `<li><strong>${escapeHtml(section.headline)}</strong><br>${escapeHtml(`${copy.whyPrefix}: ${section.why}`)}<br><em>${escapeHtml(`${copy.fixPrefix}:`)}</em> ${section.fix.map((step) => `<code>${escapeHtml(step)}</code>`).join(escapeHtml(copy.thenSeparator))}</li>`),
    "</ul>",
    `<h3>${escapeHtml(copy.howToFix)}</h3>`,
    "<ol>",
    `<li>${escapeHtml(copy.addCredentialInstruction)}<br>${fixCommands.map((command) => `<code>${escapeHtml(command)}</code>`).join("<br>")}</li>`,
    `<li>${escapeHtml(copy.removeCredentialInstruction)} <code>${escapeHtml(copy.removeCommand)}</code> ${escapeHtml(copy.removeCommandHint)}</li>`,
    `<li>${escapeHtml(copy.dashboardInstruction.replace("{links}", ""))} ${dashboardLinks.map((link) => `<a href="${escapeHtml(link)}">${escapeHtml(link)}</a>`).join(" ")}</li>`,
    "</ol>",
    `<h3>${escapeHtml(copy.whyYouGot)}</h3>`,
    `<p>${escapeHtml(whyBody)}</p>`,
    `<p>${escapeHtml(copy.questions).replace("{email}", `<a href="mailto:${CODEROUTER_SUPPORT_EMAIL}">${CODEROUTER_SUPPORT_EMAIL}</a>`)}</p>`,
    `<p>${escapeHtml(copy.signature)}</p>`,
  ];

  return {
    idempotencyKey: accountHealthIdempotencyKey(input.recipient, input.notices),
    from: `cmux coderouter <${input.from}>`,
    to: input.recipient.email,
    replyTo: CODEROUTER_SUPPORT_EMAIL,
    subject,
    text: textParts.join("\n"),
    html: htmlParts.join("\n"),
  };
}

function accountHealthIdempotencyKey(
  recipient: Recipient,
  notices: readonly BrokenAccountNotice[],
): string {
  const material = [
    recipient.email.trim().toLowerCase(),
    ...notices
      .map((notice) => `${notice.source}:${notice.accountId}`)
      .sort(),
  ].join("\n");
  return `coderouter-account-health-${createHash("sha256").update(material).digest("hex")}`;
}

type NoticeSection = { readonly headline: string; readonly why: string; readonly fix: readonly string[] };

/** Per-kind explanation of what happened and the exact repair, in the user's terms. */
export function noticeSection(notice: BrokenAccountNotice, teamName: string | null): NoticeSection {
  return noticeSectionWithCopy(notice, teamName, ENGLISH_ACCOUNT_HEALTH_COPY);
}

function noticeSectionWithCopy(
  notice: BrokenAccountNotice,
  teamName: string | null,
  copy: AccountHealthCopy,
): NoticeSection {
  const name = notice.label && notice.identifier
    ? `${notice.identifier} (${notice.label})`
    : notice.label || notice.identifier || notice.accountId.slice(0, 8);
  const when = notice.brokenAt
    ? renderTemplate(copy.whenSuffix, { date: notice.brokenAt.toISOString().replace("T", " ").slice(0, 16) })
    : "";
  const team = teamName ? renderTemplate(copy.teamSuffix, { team: teamName }) : "";
  const id = notice.accountId.slice(0, 8);
  const removeStep = `cmux coderouter accounts remove ${id}`;
  switch (notice.kind) {
    case "claude":
      return {
        headline: renderTemplate(copy.claudeHeadline, { name, team, id }),
        why: renderTemplate(copy.claudeWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add claude --label ${shellWord(notice.label || "work")}`, removeStep],
      };
    case "anthropic-key":
      return {
        headline: renderTemplate(copy.anthropicKeyHeadline, { name, team, id }),
        why: renderTemplate(copy.anthropicKeyWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add anthropic-key --label ${shellWord(notice.label || "work")}`, removeStep],
      };
    case "bedrock":
      return {
        headline: renderTemplate(copy.bedrockHeadline, { name, team, id }),
        why: renderTemplate(copy.bedrockWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add bedrock --region <region> --label ${shellWord(notice.label || "bedrock")}`, removeStep],
      };
    case "codex":
      return {
        headline: renderTemplate(copy.codexHeadline, { name, team, id }),
        why: renderTemplate(copy.subscriptionWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add ${notice.kind}`, removeStep],
      };
    case "opencode":
      return {
        headline: renderTemplate(copy.opencodeHeadline, { name, team, id }),
        why: renderTemplate(copy.subscriptionWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add ${notice.kind}`, removeStep],
      };
    default:
      return {
        headline: renderTemplate(copy.genericHeadline, { kind: notice.kind, name, team, id }),
        why: renderTemplate(copy.genericWhy, { code: notice.failureCode, when }),
        fix: [`cmux coderouter accounts add ${notice.kind}`, removeStep],
      };
  }
}

function uniqueFixCommands(notices: readonly BrokenAccountNotice[], copy: AccountHealthCopy): string[] {
  const commands = new Set<string>();
  for (const notice of notices) {
    switch (notice.kind) {
      case "claude":
        commands.add("cmux coderouter accounts add claude");
        break;
      case "anthropic-key":
        commands.add("ANTHROPIC_API_KEY=<new key> cmux coderouter accounts add anthropic-key");
        break;
      case "bedrock":
        commands.add(`cmux coderouter accounts add bedrock --region <region>   ${copy.bedrockEnvironmentHint}`);
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
    const recipient = stackRecipient(user);
    if (recipient) return [recipient];
  }
  const team = await app.getTeam(notice.teamId).catch(() => null);
  if (!team) {
    // Personal organizations use the user id as the team id.
    const user = await app.getUser(notice.teamId).catch(() => null);
    const recipient = stackRecipient(user);
    return recipient ? [recipient] : [];
  }
  const members = await team.listUsers().catch(() => []);
  return members
    .map(stackRecipient)
    .filter((member): member is Recipient => member !== null)
    .filter((member) => member.email.length > 0);
}

function stackRecipient(user: unknown): Recipient | null {
  if (!user || typeof user !== "object") return null;
  const value = user as { readonly primaryEmail?: unknown; readonly displayName?: unknown; readonly locale?: unknown };
  if (typeof value.primaryEmail !== "string" || value.primaryEmail.length === 0) return null;
  const rawLocale = typeof value.locale === "string" ? value.locale : undefined;
  const locale = rawLocale && (routing.locales as readonly string[]).includes(rawLocale)
    ? rawLocale as Locale
    : undefined;
  return { email: value.primaryEmail, name: typeof value.displayName === "string" ? value.displayName : null, locale };
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
      }, { idempotencyKey: email.idempotencyKey });
      if (result.error) throw new Error(`resend: ${result.error.message}`);
    },
    fromEmail: () => process.env.CMUX_CODEROUTER_FROM_EMAIL?.trim() || DEFAULT_CODEROUTER_FROM_EMAIL,
    now: () => new Date(),
  };
}
