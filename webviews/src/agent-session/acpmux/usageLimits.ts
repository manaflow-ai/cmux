import type { Translate } from "./i18n";
import type { AcpmuxUsageLimits } from "./model";

type LimitWindow = AcpmuxUsageLimits["windows"][number];

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/// acpmux's `usageLimits` (claude_stdio/usage_limits.rs) when it is well formed: windows without
/// an id or a finite percent are dropped, a reset time is kept only when it is a real one, and
/// nothing is left of a value with no window.
export function usageLimitsOf(value: unknown): AcpmuxUsageLimits | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const windows = (value as { windows?: unknown }).windows;
  if (!Array.isArray(windows)) return undefined;
  const kept: LimitWindow[] = [];
  for (const entry of windows) {
    if (!entry || typeof entry !== "object") continue;
    const { id, usedPercent, resetsAt } = entry as Record<string, unknown>;
    if (typeof id !== "string" || !id.trim() || !finite(usedPercent)) continue;
    const limit: LimitWindow = { id, usedPercent: Math.min(100, Math.max(0, usedPercent)) };
    // A time JavaScript's Date cannot hold would throw when formatted; drop it like a missing one.
    if (finite(resetsAt) && resetsAt > 0 && Number.isFinite(new Date(resetsAt * 1000).getTime())) {
      limit.resetsAt = resetsAt;
    }
    kept.push(limit);
  }
  return kept.length ? { windows: kept } : undefined;
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
/// there is nothing to show (the card says Not reported).
export function usageLimitsLabel(value: unknown, t: Translate, locale?: string): string | undefined {
  if (typeof value === "string") return value.trim() || undefined;
  const limits = usageLimitsOf(value);
  if (!limits) return undefined;
  return limits.windows
    .map((limit) => {
      const values = { name: windowName(limit.id, t), percent: percent(limit.usedPercent, locale) };
      return limit.resetsAt === undefined
        ? t("status.usageLimit.used", values)
        : t("status.usageLimit.usedResets", { ...values, time: resetTime(limit.resetsAt, locale) });
    })
    .join(" · ");
}
