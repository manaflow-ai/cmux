import type { Translate } from "./i18n";
import type { AcpmuxUsageLimits } from "./model";

type LimitWindow = AcpmuxUsageLimits["windows"][number];

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const nonEmpty = (value: unknown): value is string => typeof value === "string" && value.trim() !== "";

function creditsOf(value: unknown): AcpmuxUsageLimits["credits"] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const { balance, unlimited } = value as Record<string, unknown>;
  if (unlimited === true) return { unlimited: true };
  return nonEmpty(balance) ? { balance: balance.trim() } : undefined;
}

/// acpmux's `usageLimits` (Claude's from claude_stdio/usage_limits.rs, Codex's from
/// codex_app_server/usage_limits.rs) when it is well formed: windows without an id or a finite
/// percent are dropped, a reset time is kept only when it is a real one, and nothing is left of a
/// value with neither a window nor credits.
export function usageLimitsOf(value: unknown): AcpmuxUsageLimits | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as { windows?: unknown; plan?: unknown; credits?: unknown };
  const windows = Array.isArray(raw.windows) ? raw.windows : [];
  const kept: LimitWindow[] = [];
  for (const entry of windows) {
    if (!entry || typeof entry !== "object") continue;
    const { id, usedPercent, resetsAt, windowMins } = entry as Record<string, unknown>;
    if (typeof id !== "string" || !id.trim() || !finite(usedPercent)) continue;
    const limit: LimitWindow = { id, usedPercent: Math.min(100, Math.max(0, usedPercent)) };
    // A time JavaScript's Date cannot hold would throw when formatted; drop it like a missing one.
    if (finite(resetsAt) && resetsAt > 0 && Number.isFinite(new Date(resetsAt * 1000).getTime())) {
      limit.resetsAt = resetsAt;
    }
    if (finite(windowMins) && windowMins > 0) limit.windowMins = windowMins;
    kept.push(limit);
  }
  const credits = creditsOf(raw.credits);
  if (!kept.length && !credits) return undefined;
  return {
    windows: kept,
    ...(nonEmpty(raw.plan) ? { plan: raw.plan.trim() } : {}),
    ...(credits ? { credits } : {}),
  };
}

function windowName(id: string, t: Translate): string {
  switch (id) {
    case "session":
      return t("status.usageLimit.session");
    case "weekly":
      return t("status.usageLimit.weekly");
    case "weekly_opus":
      return t("status.usageLimit.weeklyOpus");
    case "weekly_sonnet":
      return t("status.usageLimit.weeklySonnet");
    default:
      return id;
  }
}

/// The reset time with its date and time zone: a weekly window can reset days from now.
function resetTime(seconds: number, locale?: string): string {
  const options: Intl.DateTimeFormatOptions = {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  };
  try {
    return new Intl.DateTimeFormat(locale, options).format(seconds * 1000);
  } catch {
    return new Intl.DateTimeFormat(undefined, options).format(seconds * 1000);
  }
}

function percent(value: number, locale?: string): string {
  try {
    return new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(value);
  } catch {
    return String(Math.round(value * 10) / 10);
  }
}

/// The Session status card's Usage limits value: a harness's own text as it is, or each window
/// acpmux reported with its share used and, only when it was reported, its reset time. Unset when
/// there is nothing to show (the card says No limit reported yet, or hides the row).
export function usageLimitsLabel(value: unknown, t: Translate, locale?: string): string | undefined {
  if (typeof value === "string") return value.trim() || undefined;
  const limits = usageLimitsOf(value);
  if (!limits?.windows.length) return undefined;
  return limits.windows
    .map((limit) => {
      const values = { name: windowName(limit.id, t), percent: percent(limit.usedPercent, locale) };
      return limit.resetsAt === undefined
        ? t("status.usageLimit.used", values)
        : t("status.usageLimit.usedResets", { ...values, time: resetTime(limit.resetsAt, locale) });
    })
    .join(" · ");
}

// The plan usage popover and Session Info's Plan limits rows (PlanUsageCard.tsx), after Claude
// desktop's "Plan usage limits" card and Codex's ring popover (Leo, 2026-11-04).

/// The share of the plan the ring draws: the window closest to its cap, since that one stops the
/// chat first. Unset with no window (credits alone fill no ring).
export function planUsedFraction(limits: AcpmuxUsageLimits | undefined): number | undefined {
  if (!limits?.windows.length) return undefined;
  return Math.max(...limits.windows.map((limit) => limit.usedPercent)) / 100;
}

/// A window's name as the references write it: "5-hour limit", "Weekly limit", "Weekly · Opus"; a
/// Codex window of another length by its length, and one with none as "Limit".
export function planWindowName(limit: LimitWindow, t: Translate): string {
  switch (limit.id) {
    case "session":
      return t("planUsage.window.session");
    case "weekly":
      return t("planUsage.window.weekly");
    case "weekly_opus":
      return t("planUsage.window.weeklyOpus");
    case "weekly_sonnet":
      return t("planUsage.window.weeklySonnet");
  }
  const minutes = limit.windowMins;
  if (minutes === undefined) return t("planUsage.window.other");
  if (minutes < 60) return t("planUsage.window.minutes", { minutes });
  if (minutes < 1440) return t("planUsage.window.hours", { hours: Math.round(minutes / 60) });
  return t("planUsage.window.days", { days: Math.round(minutes / 1440) });
}

/// When the window resets, as Claude desktop says it: the time alone within the next day
/// ("Resets at 10:00 PM"), the weekday and time within the week ("Resets Mon 3:00 PM"), else the
/// date. Unset when the harness gave no reset time.
export function planResetLabel(
  limit: LimitWindow,
  t: Translate,
  now: number = Date.now(),
  locale?: string,
): string | undefined {
  if (limit.resetsAt === undefined) return undefined;
  const at = limit.resetsAt * 1000;
  const format = (options: Intl.DateTimeFormatOptions) => {
    try {
      return new Intl.DateTimeFormat(locale, options).format(at);
    } catch {
      return new Intl.DateTimeFormat(undefined, options).format(at);
    }
  };
  const time = format({ hour: "numeric", minute: "2-digit" });
  const ahead = at - now;
  if (ahead < 24 * 3_600_000) return t("planUsage.resetsAt", { time });
  const day = format(ahead < 6 * 24 * 3_600_000 ? { weekday: "short" } : { month: "short", day: "numeric" });
  return t("planUsage.resetsOn", { day, time });
}

/// A window's share as the popover writes it: whole percent, never "0%" for a sliver used.
export function planPercent(usedPercent: number): number {
  return usedPercent > 0 && usedPercent < 1 ? 1 : Math.round(usedPercent);
}

/// The plan's name as a title: Codex's `pro` reads "Pro".
export function planName(plan: string | undefined): string | undefined {
  if (!plan) return undefined;
  return plan
    .split(/[_\s-]+/)
    .filter(Boolean)
    .map((word) => word[0]!.toUpperCase() + word.slice(1))
    .join(" ");
}

/// The credits value: "56,766 credits" for a whole balance, the balance as sent otherwise, or
/// "Unlimited". Unset with no credits reported.
export function planCreditsLabel(
  credits: AcpmuxUsageLimits["credits"],
  t: Translate,
  locale?: string,
): string | undefined {
  if (!credits) return undefined;
  if (credits.unlimited) return t("planUsage.creditsUnlimited");
  if (!credits.balance) return undefined;
  const value = Number(credits.balance);
  let count = credits.balance;
  if (Number.isFinite(value)) {
    try {
      count = new Intl.NumberFormat(locale, { maximumFractionDigits: 2 }).format(value);
    } catch {
      count = String(value);
    }
  }
  return t("planUsage.creditsValue", { count });
}

/// The page where the harness's account shows its usage in full, by the chat's family: Claude's
/// usage settings and Codex's. Unset for any other harness, so no link is drawn that may be wrong.
export function planUsageUrl(family: string | undefined): string | undefined {
  const name = family?.toLowerCase() ?? "";
  if (name.startsWith("claude")) return "https://claude.ai/settings/usage";
  if (name.startsWith("codex")) return "https://chatgpt.com/codex/settings/usage";
  return undefined;
}

/// Session Info's Plan limits rows (Usage section, web and native): each window's name with its
/// share used and, when reported, its reset time, then the credits. Empty with none reported.
export function planLimitRows(
  limits: AcpmuxUsageLimits | undefined,
  t: Translate,
  now: number = Date.now(),
  locale?: string,
): { id: string; name: string; value: string }[] {
  if (!limits) return [];
  const rows = limits.windows.map((limit) => {
    const percent = t("planUsage.percentUsed", { percent: planPercent(limit.usedPercent) });
    const reset = planResetLabel(limit, t, now, locale);
    return { id: limit.id, name: planWindowName(limit, t), value: reset ? `${percent} · ${reset}` : percent };
  });
  const credits = planCreditsLabel(limits.credits, t, locale);
  if (credits) rows.push({ id: "credits", name: t("planUsage.credits"), value: credits });
  return rows;
}
