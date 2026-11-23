/**
 * Usage statements for the cmux Cloud $1 pass (RFD 0052). On days 21, 27 and
 * 30 of a pass its buyer gets a short statement of what they used; on day 30
 * the statement also asks: Plus, Pro, or not now.
 *
 * Everything here is pure: which statement is due, the statement as plain
 * data, and its text for the email and the Plan & billing notice. Storage is
 * services/billing/cloudIntroStatementStore.ts, the cron step
 * services/billing/cloudIntroStatementJob.ts, the usage read
 * services/billing/cloudPassUsage.ts.
 *
 * A statement never shows a number that was not read: a usage figure the
 * platform could not read is shown as "not measured", with what the pass
 * includes and how many days remain.
 */
import {
  CLOUD_INTRO_INCLUDED,
  CLOUD_INTRO_KEEP_DAYS,
  CLOUD_INTRO_TERM_DAYS,
} from "./cloudIntro";
import { GO_PRICING_USD, PRO_PRICING_USD } from "./plans";

const DAY_MS = 24 * 60 * 60 * 1000;

/** The pass days a statement goes out on; the last one carries the ask. */
export const CLOUD_INTRO_STATEMENT_DAYS = [21, 27, 30] as const;
export type CloudIntroStatementDay = (typeof CLOUD_INTRO_STATEMENT_DAYS)[number];
export const CLOUD_INTRO_ASK_DAY: CloudIntroStatementDay = 30;

/**
 * A cron run that comes late may still send a due statement this long after
 * the pass ended; after that nothing more is sent for the pass.
 */
export const CLOUD_INTRO_STATEMENT_LATE_MS = DAY_MS;

/** `?pass=` values Plan & billing understands. */
export const CLOUD_INTRO_PASS_PARAM = "pass";
export const CLOUD_INTRO_PASS_NOT_NOW = "not-now";
export const CLOUD_INTRO_PASS_RENEW = "renew";

/** How one statement day went. `superseded`: a later day came due first, so this one is never sent. */
export type CloudIntroStatementDelivery = "pending" | "emailed" | "email_failed" | "no_email" | "superseded";

export type CloudIntroStatementRecord = {
  readonly at: string;
  readonly delivery: CloudIntroStatementDelivery;
  readonly statement?: CloudIntroStatement;
};

/** The `statements` column: one record per statement day, keyed by the day. */
export type CloudIntroStatementLog = Readonly<Partial<Record<`${CloudIntroStatementDay}`, CloudIntroStatementRecord>>>;

/**
 * What the buyer chose about Plus, as a statement shows it:
 * - `none`: they did not choose to continue on Plus; nothing will be charged.
 * - `saved_ask_first`: they chose it, and the later charge is off; we ask first.
 * - `will_charge`: they chose it, the card is saved, and the charge is on.
 * - `charged`: Plus started on the saved card.
 * - `charge_failed`: the charge did not go through; nothing was charged.
 */
export type CloudIntroRenewalView = "none" | "saved_ask_first" | "will_charge" | "charged" | "charge_failed";

/** The pass row fields the statements read. */
export type CloudIntroStatementPass = {
  readonly checkoutSessionId: string;
  readonly stackUserId: string;
  readonly status: "open" | "granted" | "refused";
  readonly renewOnPlus: boolean;
  readonly startedAt: Date | null;
  readonly endsAt: Date | null;
  readonly statements: CloudIntroStatementLog;
};

/** When statement `day` of a pass that started at `startedAt` comes due: the start of that pass day. */
export function cloudIntroStatementDueAt(startedAt: Date, day: CloudIntroStatementDay): Date {
  return new Date(startedAt.getTime() + (day - 1) * DAY_MS);
}

export type CloudIntroStatementDue = {
  /** The statement to send now. */
  readonly day: CloudIntroStatementDay;
  /** Earlier days that came due but were never sent; they are recorded as superseded, never sent later. */
  readonly superseded: readonly CloudIntroStatementDay[];
};

/**
 * The statement due for `pass` at `now` and not yet sent, or null. Only a
 * granted pass gets statements. Only the latest due day is sent: a cron that
 * missed day 21 and runs on day 27 sends day 27 and marks 21 superseded. A day
 * at or before one already recorded is never due again.
 */
export function dueCloudIntroStatement(pass: CloudIntroStatementPass, now: Date): CloudIntroStatementDue | null {
  if (pass.status !== "granted" || !pass.startedAt || !pass.endsAt) return null;
  if (now.getTime() >= pass.endsAt.getTime() + CLOUD_INTRO_STATEMENT_LATE_MS) return null;
  const recorded = CLOUD_INTRO_STATEMENT_DAYS.filter((day) => pass.statements[`${day}`]);
  const lastRecorded = recorded.length > 0 ? Math.max(...recorded) : 0;
  const started = pass.startedAt;
  const due = CLOUD_INTRO_STATEMENT_DAYS.filter((day) =>
    day > lastRecorded && cloudIntroStatementDueAt(started, day).getTime() <= now.getTime());
  if (due.length === 0) return null;
  const day = due[due.length - 1]!;
  return { day, superseded: due.slice(0, -1) };
}

/**
 * Usage of the buyer's machines between two instants. Each figure is null
 * when it could not be read; `unavailable` when nothing could be read.
 */
export type CloudPassUsage =
  | {
      readonly status: "read";
      /** Minutes the Chief was awake, or null when the Chief is not measured on its own. */
      readonly chiefAwakeMinutes: number | null;
      /** Machine-minutes: one vCPU awake for one minute, across all the buyer's machines. */
      readonly machineMinutes: number | null;
      /** Machines started in the window. */
      readonly machinesStarted: number | null;
    }
  | { readonly status: "unavailable" };

export const CLOUD_PASS_USAGE_UNAVAILABLE: CloudPassUsage = { status: "unavailable" };

export type CloudPassUsageReader = (input: {
  readonly stackUserId: string;
  readonly from: Date;
  readonly to: Date;
}) => Promise<CloudPassUsage>;

/** A statement as plain data: what is stored on the pass row and rendered for email and the dashboard. */
export type CloudIntroStatement = {
  readonly day: CloudIntroStatementDay;
  /** The instant the usage figures run to. */
  readonly asOf: string;
  readonly endsAt: string;
  readonly daysLeft: number;
  readonly chief: { readonly includedHours: number; readonly usedHours: number | null };
  readonly machines: {
    readonly includedMinutes: number;
    readonly usedMinutes: number | null;
    readonly started: number | null;
  };
  readonly renewal: CloudIntroRenewalView;
  /** When the saved card is charged for Plus; set for `will_charge` and `charged`. */
  readonly chargeOn: string | null;
  readonly plusMonthlyUsd: number;
  readonly proMonthlyUsd: number;
  /** Day 30 without Plus started: the three choices. */
  readonly ask: boolean;
};

/** When the saved card would be charged for Plus: the start of the pass's last day, the day-30 statement. */
export function cloudIntroRenewalChargeAt(startedAt: Date): Date {
  return cloudIntroStatementDueAt(startedAt, CLOUD_INTRO_ASK_DAY);
}

/** The day-30 Plus charge as recorded on the pass row; null before any attempt. */
export type CloudIntroRenewalStatus =
  | "started"
  | "succeeded"
  | "failed"
  | "requires_action"
  | "unknown"
  | "skipped_has_plan";

export type CloudIntroRenewalFacts = {
  readonly renewOnPlus: boolean;
  readonly paymentMethodId: string | null;
  readonly renewalStatus?: CloudIntroRenewalStatus | null;
  readonly endsAt: Date | null;
};

/**
 * How a statement shows the buyer's Plus choice, from the row as it is now.
 * Null while a charge is in flight or its outcome is unknown: the statement
 * waits rather than say something that may be false.
 */
export function cloudIntroRenewalView(
  pass: CloudIntroRenewalFacts,
  chargeEnabled: boolean,
  now: Date,
): CloudIntroRenewalView | null {
  switch (pass.renewalStatus ?? null) {
    case "succeeded":
      return "charged";
    case "failed":
    case "requires_action":
      return "charge_failed";
    case "started":
    case "unknown":
      return null;
    case "skipped_has_plan":
      return "none";
    default:
      break;
  }
  if (!pass.renewOnPlus) return "none";
  const charging = chargeEnabled && pass.paymentMethodId !== null && pass.endsAt !== null && now < pass.endsAt;
  return charging ? "will_charge" : "saved_ask_first";
}

/** A stored statement shown again with the buyer's Plus choice as it is now (turned off, charged, failed). */
export function withCurrentRenewal(
  statement: CloudIntroStatement,
  renewal: CloudIntroRenewalView | null,
  startedAt: Date | null,
): CloudIntroStatement {
  if (!renewal || renewal === statement.renewal) return statement;
  return {
    ...statement,
    renewal,
    chargeOn: (renewal === "will_charge" || renewal === "charged") && startedAt
      ? cloudIntroRenewalChargeAt(startedAt).toISOString()
      : null,
    ask: statement.day === CLOUD_INTRO_ASK_DAY && renewal !== "charged",
  };
}

export function buildCloudIntroStatement(input: {
  readonly pass: CloudIntroStatementPass;
  readonly day: CloudIntroStatementDay;
  readonly usage: CloudPassUsage;
  readonly now: Date;
  readonly renewal: CloudIntroRenewalView;
}): CloudIntroStatement {
  const { pass, day, usage, now, renewal } = input;
  if (!pass.startedAt || !pass.endsAt) throw new Error("cmux Cloud pass statement needs a granted pass");
  const asOf = new Date(Math.min(now.getTime(), pass.endsAt.getTime()));
  const read = usage.status === "read" ? usage : null;
  const chiefMinutes = read?.chiefAwakeMinutes ?? null;
  return {
    day,
    asOf: asOf.toISOString(),
    endsAt: pass.endsAt.toISOString(),
    daysLeft: Math.max(0, Math.ceil((pass.endsAt.getTime() - now.getTime()) / DAY_MS)),
    chief: {
      includedHours: CLOUD_INTRO_INCLUDED.chiefAwakeHours,
      usedHours: chiefMinutes === null ? null : Math.round((chiefMinutes / 60) * 10) / 10,
    },
    machines: {
      includedMinutes: CLOUD_INTRO_INCLUDED.machineMinutes,
      usedMinutes: read?.machineMinutes ?? null,
      started: read?.machinesStarted ?? null,
    },
    renewal,
    chargeOn: renewal === "will_charge" || renewal === "charged"
      ? cloudIntroRenewalChargeAt(pass.startedAt).toISOString()
      : null,
    plusMonthlyUsd: GO_PRICING_USD.month.billedAmount,
    proMonthlyUsd: PRO_PRICING_USD.month.billedAmount,
    ask: day === CLOUD_INTRO_ASK_DAY && renewal !== "charged",
  };
}

/** The English strings, from `emails.cloudPassStatement` in messages/en.json. */
export type CloudIntroStatementCopy = {
  readonly subject: string;
  readonly subjectLastDay: string;
  readonly title: string;
  readonly asOf: string;
  readonly daysLeft: string;
  readonly lastDay: string;
  readonly ended: string;
  readonly chiefUsed: string;
  readonly chiefNotMeasured: string;
  readonly machinesUsed: string;
  readonly machinesNotMeasured: string;
  readonly machinesStarted: string;
  readonly notCharged: string;
  readonly renewSaved: string;
  readonly willCharge: string;
  readonly turnOff: string;
  readonly onPlus: string;
  readonly chargeFailed: string;
  readonly askTitle: string;
  readonly choosePlus: string;
  readonly choosePro: string;
  readonly chooseNotNow: string;
  readonly after: string;
  readonly signoff: string;
};

export type CloudIntroStatementLinks = {
  readonly plus: string;
  readonly pro: string;
  readonly notNow: string;
  readonly turnOff: string;
};

/** Links for a statement; `origin` is "" for the dashboard and the site origin for email. */
export function cloudIntroStatementLinks(origin: string): CloudIntroStatementLinks {
  const back = encodeURIComponent("/dashboard/billing");
  return {
    plus: `${origin}/api/billing/checkout?plan=go&interval=month&cmux_source=cloud_pass&returnTo=${back}`,
    pro: `${origin}/api/billing/checkout?plan=pro&interval=month&cmux_source=cloud_pass&returnTo=${back}`,
    notNow: `${origin}/dashboard/billing?${CLOUD_INTRO_PASS_PARAM}=${CLOUD_INTRO_PASS_NOT_NOW}`,
    turnOff: `${origin}/dashboard/billing?${CLOUD_INTRO_PASS_PARAM}=${CLOUD_INTRO_PASS_RENEW}`,
  };
}

export type CloudIntroStatementChoice = { readonly key: "plus" | "pro" | "not_now"; readonly label: string; readonly href: string };

/** A statement as text: the same lines for the email and the Plan & billing notice. */
export type CloudIntroStatementText = {
  readonly subject: string;
  readonly title: string;
  readonly lines: string[];
  /** Day 30: Plus, Pro, not now. */
  readonly askTitle: string | null;
  readonly choices: CloudIntroStatementChoice[];
  readonly after: string | null;
  /** The link that turns the later Plus charge off, for `will_charge`. */
  readonly turnOff: { readonly label: string; readonly href: string } | null;
};

function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, key: string) => (key in values ? String(values[key]) : match));
}

function count(value: number): string {
  return value.toLocaleString("en-US");
}

function day(value: string): string {
  return new Date(value).toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" });
}

export function cloudIntroStatementText(
  statement: CloudIntroStatement,
  copy: CloudIntroStatementCopy,
  links: CloudIntroStatementLinks,
): CloudIntroStatementText {
  const lines: string[] = [fill(copy.asOf, { date: day(statement.asOf) })];
  lines.push(
    statement.daysLeft > 1
      ? fill(copy.daysLeft, { days: statement.daysLeft, date: day(statement.endsAt) })
      : statement.daysLeft === 1
        ? fill(copy.lastDay, { date: day(statement.endsAt) })
        : fill(copy.ended, { date: day(statement.endsAt) }),
  );
  lines.push(statement.chief.usedHours === null
    ? fill(copy.chiefNotMeasured, { included: count(statement.chief.includedHours) })
    : fill(copy.chiefUsed, { used: count(statement.chief.usedHours), included: count(statement.chief.includedHours) }));
  lines.push(statement.machines.usedMinutes === null
    ? fill(copy.machinesNotMeasured, { included: count(statement.machines.includedMinutes) })
    : fill(copy.machinesUsed, {
        used: count(statement.machines.usedMinutes),
        included: count(statement.machines.includedMinutes),
      }));
  if (statement.machines.started !== null) {
    lines.push(fill(copy.machinesStarted, { count: count(statement.machines.started) }));
  }
  const amount = statement.plusMonthlyUsd;
  let turnOff: CloudIntroStatementText["turnOff"] = null;
  switch (statement.renewal) {
    case "none":
      lines.push(copy.notCharged);
      break;
    case "saved_ask_first":
      lines.push(copy.renewSaved);
      break;
    case "will_charge":
      lines.push(fill(copy.willCharge, { date: day(statement.chargeOn ?? statement.endsAt), amount, url: links.turnOff }));
      turnOff = { label: copy.turnOff, href: links.turnOff };
      break;
    case "charged":
      lines.push(fill(copy.onPlus, { amount }));
      break;
    case "charge_failed":
      lines.push(copy.chargeFailed);
      break;
  }
  const choices: CloudIntroStatementChoice[] = statement.ask
    ? [
        { key: "plus", label: fill(copy.choosePlus, { amount }), href: links.plus },
        { key: "pro", label: fill(copy.choosePro, { amount: statement.proMonthlyUsd }), href: links.pro },
        { key: "not_now", label: copy.chooseNotNow, href: links.notNow },
      ]
    : [];
  return {
    subject: statement.day === CLOUD_INTRO_ASK_DAY ? copy.subjectLastDay : fill(copy.subject, { days: statement.daysLeft }),
    title: fill(copy.title, { day: statement.day, days: CLOUD_INTRO_TERM_DAYS }),
    lines,
    askTitle: statement.ask ? copy.askTitle : null,
    choices,
    after: statement.ask ? fill(copy.after, { keepDays: CLOUD_INTRO_KEEP_DAYS }) : null,
    turnOff,
  };
}

export type CloudIntroStatementEmail = {
  readonly from: string;
  readonly to: string[];
  readonly replyTo: string;
  readonly subject: string;
  readonly text: string;
  readonly html: string;
  readonly headers: Readonly<Record<string, string>>;
};

/** The statement email: plain text first, a minimal HTML twin, no tracking. */
export function buildCloudIntroStatementEmail(input: {
  readonly from: string;
  readonly to: string;
  readonly replyTo: string;
  readonly checkoutSessionId: string;
  readonly statement: CloudIntroStatement;
  readonly copy: CloudIntroStatementCopy;
  readonly links: CloudIntroStatementLinks;
}): CloudIntroStatementEmail {
  const text = cloudIntroStatementText(input.statement, input.copy, input.links);
  const plain = [text.title, "", ...text.lines];
  const html = [`<p><strong>${escapeHtml(text.title)}</strong></p>`, ...text.lines.map((line) => `<p>${linkify(line)}</p>`)];
  if (text.askTitle) {
    plain.push("", text.askTitle, ...text.choices.map((choice) => `${choice.label}: ${choice.href}`));
    html.push(
      `<p>${escapeHtml(text.askTitle)}</p>`,
      `<p>${text.choices.map((choice) => `<a href="${escapeHtml(choice.href)}">${escapeHtml(choice.label)}</a>`).join(" &middot; ")}</p>`,
    );
  }
  if (text.after) {
    plain.push("", text.after);
    html.push(`<p style="color:#666">${escapeHtml(text.after)}</p>`);
  }
  plain.push("", input.copy.signoff);
  html.push(`<p>${escapeHtml(input.copy.signoff).replaceAll("\n", "<br>")}</p>`);
  return {
    from: input.from,
    to: [input.to],
    replyTo: input.replyTo,
    subject: text.subject,
    text: plain.join("\n"),
    html: html.join("\n"),
    headers: {
      "Auto-Submitted": "auto-generated",
      "X-Entity-Ref-ID": `cloud-pass-statement/${input.checkoutSessionId}/${input.statement.day}`,
    },
  };
}

/** The Plan & billing notice: the latest statement's text with dashboard links. */
export type CloudIntroStatementNotice = CloudIntroStatementText & { readonly day: CloudIntroStatementDay };

export function cloudIntroStatementNotice(
  statement: CloudIntroStatement,
  copy: CloudIntroStatementCopy,
): CloudIntroStatementNotice {
  return { day: statement.day, ...cloudIntroStatementText(statement, copy, cloudIntroStatementLinks("")) };
}

/** The latest statement on a pass that a notice may still show: until the kept days after the pass end. */
export function latestCloudIntroStatement(
  pass: Pick<CloudIntroStatementPass, "endsAt" | "statements">,
  now: Date,
): CloudIntroStatement | null {
  if (!pass.endsAt || now.getTime() >= pass.endsAt.getTime() + CLOUD_INTRO_KEEP_DAYS * DAY_MS) return null;
  for (const statementDay of [...CLOUD_INTRO_STATEMENT_DAYS].reverse()) {
    const statement = pass.statements[`${statementDay}`]?.statement;
    if (statement) return statement;
  }
  return null;
}

/** Reads the `statements` column defensively: anything that is not a record of known days is dropped. */
export function cloudIntroStatementLog(raw: unknown): CloudIntroStatementLog {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const log: Partial<Record<`${CloudIntroStatementDay}`, CloudIntroStatementRecord>> = {};
  for (const statementDay of CLOUD_INTRO_STATEMENT_DAYS) {
    const value = (raw as Record<string, unknown>)[`${statementDay}`];
    if (value && typeof value === "object" && typeof (value as { at?: unknown }).at === "string") {
      log[`${statementDay}`] = value as CloudIntroStatementRecord;
    }
  }
  return log;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]!));
}

/** Escapes a line and makes its one http(s) URL, if any, a link. */
function linkify(line: string): string {
  const match = /https?:\/\/\S+/.exec(line);
  if (!match) return escapeHtml(line);
  const url = match[0];
  return `${escapeHtml(line.slice(0, match.index))}<a href="${escapeHtml(url)}">${escapeHtml(url)}</a>${escapeHtml(line.slice(match.index + url.length))}`;
}
