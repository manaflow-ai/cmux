// Session Info's Usage model, derived from the same usageStats source as UsageSection.tsx.
// The page formats and orders values; the App only draws rows and forwards actions.
import type { Translate } from "../../i18n";
import type { AcpmuxSessionEntry } from "../../sessionList";
import { byUsage, cacheUsageRows, type SessionUsageStats, UNKNOWN, usageCost, usageTokens } from "../../usageStats";
import type { AcpmuxUsageLimits } from "../../model";
import { planLimitRows } from "../../usageLimits";
import type { NativeInfoActions, NativeInfoRow, NativeInfoSection } from "./model";

export const USAGE_SYMBOL = "waveform.path";
export const USAGE_SHOWN = 5;

type OwnAction = "compact" | "subagents" | "cap";

const known = <T>(value: T | undefined, format: (value: T) => string) =>
  value === undefined ? UNKNOWN : format(value);

function ownRows(
  stats: SessionUsageStats,
  t: Translate,
  locale: string | undefined,
  actions: NativeInfoActions,
  onCompact?: () => void,
  onShowSubagents?: () => void,
): NativeInfoRow[] {
  const tokens = (value: number) => usageTokens(value, locale);
  const subagents = [stats.subagentsLive, stats.subagents1h, stats.subagents24h];
  const rows: Array<{
    id: string;
    name: string;
    value: string;
    action?: OwnAction;
  }> = [
    {
      id: "cost",
      name: t("sessionInfo.usage.cost24h"),
      value: known(stats.costUsd24h, (cost) => usageCost(cost, locale)),
    },
    ...cacheUsageRows(t, stats, locale),
    {
      id: "tokens",
      name: t("sessionInfo.usage.tokens24h"),
      value: known(stats.tokens24h, tokens),
    },
    {
      id: "context",
      name: t("sessionInfo.usage.perCall"),
      value:
        stats.contextTokens !== undefined && stats.contextWindow
          ? `${tokens(stats.contextTokens)} / ${tokens(stats.contextWindow)}`
          : known(stats.contextTokens, tokens),
      ...(onCompact ? { action: "compact" as const } : {}),
    },
    {
      id: "cap",
      name: t("sessionInfo.usage.autocompact"),
      value:
        stats.autocompact === "none"
          ? t("sessionInfo.usage.noCap")
          : stats.autocompact === "capped"
            ? known(stats.autocompactCap, tokens)
            : UNKNOWN,
      ...(stats.autocompact === "none" ? { action: "cap" as const } : {}),
    },
    {
      id: "compactions",
      name: t("sessionInfo.usage.compactions24h"),
      value: known(stats.compactions24h, String),
    },
    {
      id: "subagents",
      name: t("sessionInfo.usage.subagents"),
      value: subagents.every((count) => count === undefined)
        ? UNKNOWN
        : t("sessionInfo.usage.subagentsValue", {
            live: known(stats.subagentsLive, String),
            hour: known(stats.subagents1h, String),
            day: known(stats.subagents24h, String),
          }),
      ...(onShowSubagents ? { action: "subagents" as const } : {}),
    },
  ];
  if (stats.launcher)
    rows.push({
      id: "launcher",
      name: t("sessionInfo.usage.launcher"),
      value: stats.launcher,
    });
  return rows.map(({ id, name, value, action }): NativeInfoRow => ({
    id: `own:${id}`,
    title: name,
    trailing: value,
    ...(action === "compact" && onCompact
      ? {
          buttons: [
            {
              label: t("context.compact"),
              action: actions.add("usage.compact", onCompact),
            },
          ],
        }
      : {}),
    ...(action === "subagents" && onShowSubagents
      ? {
          buttons: [
            {
              label: t("sessionInfo.usage.showSubagents"),
              action: actions.add("usage.subagents", onShowSubagents),
            },
          ],
        }
      : {}),
    ...(action === "cap"
      ? {
          buttons: [
            {
              label: t("sessionInfo.usage.restartWithCap"),
              action: actions.add("usage.restartWithCap", () => undefined),
              disabled: true,
            },
          ],
          help: t("sessionInfo.usage.restartWithCapSoon"),
        }
      : {}),
  }));
}

export type UsageInput = {
  own?: SessionUsageStats;
  /// The account's plan usage limits this chat's harness reported (acpmux `usageLimits`).
  planLimits?: AcpmuxUsageLimits;
  sessions: readonly AcpmuxSessionEntry[];
  /// Parent may provide a memoized ranking; when absent, ranking only happens while open.
  ranked?: readonly AcpmuxSessionEntry[];
  /// Parent's memoized existence check keeps a folded section visible without sorting its rows.
  hasSessionUsage?: boolean;
  chatId?: string;
  onOpen?: (sessionId: string) => void;
  onCompact?: () => void;
  onShowSubagents?: () => void;
  locale?: string;
  sort?: "cost" | "context";
  onSortChange?: (sort: "cost" | "context") => void;
  expanded?: boolean;
  onExpandedChange?: (expanded: boolean) => void;
  open: boolean;
};

export function usageSection(
  input: UsageInput,
  actions: NativeInfoActions,
  t: Translate,
): NativeInfoSection | undefined {
  const hasSessionUsage = input.hasSessionUsage ?? input.sessions.some((entry) => Boolean(entry.usageStats));
  const planRows = planLimitRows(input.planLimits, t, Date.now(), input.locale);
  if (!input.own && !hasSessionUsage && !planRows.length) return undefined;
  const ranked = input.ranked ?? (input.open ? byUsage(input.sessions, input.sort ?? "cost") : []);
  const expanded = input.expanded === true;
  const sort = input.sort ?? "cost";
  const folds = ranked.length > USAGE_SHOWN;
  const shown = folds && !expanded ? ranked.slice(0, USAGE_SHOWN) : ranked;
  const rows: NativeInfoRow[] = [];
  if (input.own) rows.push(...ownRows(input.own, t, input.locale, actions, input.onCompact, input.onShowSubagents));
  // The plan's limits, as the composer ring's plan usage popover shows them (PlanUsageCard.tsx).
  if (planRows.length) {
    rows.push({ id: "plan", title: t("sessionInfo.usage.planLimits") });
    for (const row of planRows) rows.push({ id: `plan:${row.id}`, title: row.name, trailing: row.value });
  }
  if (ranked.length && input.onSortChange) {
    rows.push({
      id: "sort",
      title: t("sessionInfo.usage.allSessions"),
      buttons: [
        {
          label: t("sessionInfo.usage.sortCost"),
          action: actions.add("usage.sort:cost", () => input.onSortChange!("cost")),
          disabled: sort === "cost",
        },
        {
          label: t("sessionInfo.usage.sortContext"),
          action: actions.add("usage.sort:context", () => input.onSortChange!("context")),
          disabled: sort === "context",
        },
      ],
    });
  }
  for (const entry of shown) {
    const stats = entry.usageStats;
    if (!stats) continue;
    const place = entry.peer ?? entry.host;
    const named = entry.displayTitle || entry.title || entry.name || entry.sessionId;
    const title = entry.peer && named.startsWith(`${entry.peer}/`) ? named.slice(entry.peer.length + 1) : named;
    const value = sort === "context" ? stats.contextTokens : stats.costUsd24h;
    rows.push({
      id: `session:${entry.sessionId}`,
      symbol: "bubble.left",
      ...(entry.harness ? { harness: entry.harness } : {}),
      title,
      ...(place ? { detail: place } : {}),
      trailing:
        value === undefined
          ? UNKNOWN
          : sort === "context"
            ? usageTokens(value, input.locale)
            : usageCost(value, input.locale),
      ...(entry.sessionId !== input.chatId && input.onOpen
        ? {
            action: actions.add(`usage.open:${entry.sessionId}`, () => input.onOpen!(entry.sessionId)),
          }
        : {}),
    });
  }
  return {
    id: "usage",
    group: "about",
    title: t("sessionInfo.usage"),
    symbol: USAGE_SYMBOL,
    meta: input.own
      ? input.own.costUsd24h !== undefined
        ? t("sessionInfo.usage.cost24hValue", {
            cost: usageCost(input.own.costUsd24h, input.locale),
          })
        : input.own.tokens24h !== undefined
          ? t("sessionInfo.usage.tokens24hValue", {
              tokens: usageTokens(input.own.tokens24h, input.locale),
            })
          : undefined
      : undefined,
    open: input.open,
    foldable: true,
    reorderable: true,
    rows,
    ...(folds && input.onExpandedChange
      ? {
          more: {
            label: expanded ? t("summary.showFewer") : t("summary.viewAll", { n: ranked.length }),
            action: actions.add("usage.more", () => input.onExpandedChange!(!expanded)),
          },
        }
      : {}),
  };
}
