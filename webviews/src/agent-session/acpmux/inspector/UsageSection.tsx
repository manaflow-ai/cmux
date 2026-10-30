// Session Info's Usage (ChatInspector.tsx), one row in the top block like Context: what this chat
// spent in the last 24 hours, and every session acpmux lists, this Mac's and its peers', sorted by
// 24h cost or by context, so the top spenders are one glance away. Leo, 2026-10-30: "that
// visibility into huge-blue guys was (and is?) pretty bad i feel like we can make more improvements
// to acpmux/cmux-next". The numbers are acpmux's `usageStats` (usageStats.ts), refreshed on the
// session list acpmux already sends; the list is sorted only while the section is open, and only
// when the list or the sort changes.
import { useMemo, useState } from "react";
import { useT, type Translate } from "../i18n";
import { AgentMark } from "../../shared/AgentMark";
import { agentTone } from "../subagents/agentTones";
import { TonedIcon } from "../subagents/TonedIcon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSessionEntry } from "../sessionList";
import { byUsage, type SessionUsageStats, type UsageSort, usageCost, usageTokens } from "../usageStats";
import "./UsageSection.css";

const ROW_ICON = rowIconSize(12);
/// Rows the list shows before View all.
export const USAGE_SHOWN = 5;

/// The section's one-line value: this chat's 24h cost, else its 24h tokens.
export function usageMeta(t: Translate, stats: SessionUsageStats | undefined, locale?: string): string | undefined {
  if (!stats) return undefined;
  if (stats.costUsd24h !== undefined)
    return t("chatInspector.usage.cost24hValue", { cost: usageCost(stats.costUsd24h, locale) });
  return t("chatInspector.usage.tokens24hValue", { tokens: usageTokens(stats.tokens24h, locale) });
}

/// This chat's numbers, as name and value rows.
function ownRows(t: Translate, stats: SessionUsageStats, locale?: string): [string, string, string][] {
  const rows: [string, string, string][] = [];
  if (stats.costUsd24h !== undefined)
    rows.push(["cost", t("chatInspector.usage.cost24h"), usageCost(stats.costUsd24h, locale)]);
  rows.push(["tokens", t("chatInspector.usage.tokens24h"), usageTokens(stats.tokens24h, locale)]);
  if (stats.contextTokens !== undefined)
    rows.push([
      "context",
      t("chatInspector.usage.perCall"),
      stats.contextWindow
        ? `${usageTokens(stats.contextTokens, locale)} / ${usageTokens(stats.contextWindow, locale)}`
        : usageTokens(stats.contextTokens, locale),
    ]);
  rows.push([
    "cap",
    t("chatInspector.usage.autocompact"),
    stats.autocompactCap === undefined ? t("chatInspector.usage.noCap") : usageTokens(stats.autocompactCap, locale),
  ]);
  rows.push(["compactions", t("chatInspector.usage.compactions24h"), String(stats.compactions24h)]);
  rows.push([
    "subagents",
    t("chatInspector.usage.subagents"),
    t("chatInspector.usage.subagentsValue", {
      live: stats.subagentsLive,
      hour: stats.subagents1h,
      day: stats.subagents24h,
    }),
  ]);
  if (stats.launcher) rows.push(["launcher", t("chatInspector.usage.launcher"), stats.launcher]);
  return rows;
}

/// What a list row's end says for `sort`.
function sortValue(stats: SessionUsageStats, sort: UsageSort, locale?: string): string {
  if (sort === "cost")
    return stats.costUsd24h === undefined ? usageTokens(stats.tokens24h, locale) : usageCost(stats.costUsd24h, locale);
  return stats.contextTokens === undefined ? "–" : usageTokens(stats.contextTokens, locale);
}

export function UsageSection({
  own,
  sessions,
  chatId,
  onOpen,
  locale,
  sort: initialSort = "cost",
  expanded: initialExpanded = false,
}: {
  /// This chat's (`summary.usageStats`).
  own?: SessionUsageStats;
  /// Every session acpmux lists, this Mac's and its peers' (the snapshot's `sessions`).
  sessions: readonly AcpmuxSessionEntry[];
  chatId?: string;
  /// Opens a listed chat, this Mac's or a peer's; without it the rows are plain text.
  onOpen?: (sessionId: string) => void;
  locale?: string;
  /// The gallery's starting states.
  sort?: UsageSort;
  expanded?: boolean;
}) {
  const t = useT();
  const [sort, setSort] = useState<UsageSort>(initialSort);
  const [expanded, setExpanded] = useState(initialExpanded);
  const ranked = useMemo(() => byUsage(sessions, sort), [sessions, sort]);
  const folds = ranked.length > USAGE_SHOWN;
  const shown = folds && !expanded ? ranked.slice(0, USAGE_SHOWN) : ranked;
  return (
    <div className="acpmux-chat-inspector-usage" data-section="usage">
      {own && (
        <ul className="acpmux-chat-inspector-list">
          {ownRows(t, own, locale).map(([id, name, value]) => (
            <li key={id} className="acpmux-chat-inspector-row" data-usage={id}>
              <span className="acpmux-chat-inspector-row__name">{name}</span>
              <span className="acpmux-chat-inspector-row__end acpmux-chat-inspector-usage__value">{value}</span>
            </li>
          ))}
        </ul>
      )}
      {ranked.length > 0 && (
        <>
          <div className="acpmux-chat-inspector-usage__head">
            <span className="acpmux-chat-inspector-usage__title">{t("chatInspector.usage.allSessions")}</span>
            <fieldset className="acpmux-chat-inspector-usage__sort" aria-label={t("chatInspector.usage.sortBy")}>
              {(["cost", "context"] as const).map((option) => (
                <button
                  key={option}
                  type="button"
                  className="acpmux-chat-inspector-usage__sort-option"
                  aria-pressed={sort === option}
                  onClick={() => setSort(option)}
                >
                  {t(option === "cost" ? "chatInspector.usage.sortCost" : "chatInspector.usage.sortContext")}
                </button>
              ))}
            </fieldset>
          </div>
          <ul className="acpmux-chat-inspector-list" data-sort={sort}>
            {shown.map((entry) => {
              const stats = entry.usageStats!;
              const place = entry.peer ?? entry.host;
              // A peer's chat is named `<peer>/<name>` (acpmux hub/peers.rs); the row names the peer
              // after the title, so the title drops it.
              const named = entry.displayTitle || entry.title || entry.name || entry.sessionId;
              const title =
                entry.peer && named.startsWith(`${entry.peer}/`) ? named.slice(entry.peer.length + 1) : named;
              const mark = (
                <span className="acpmux-lineage__icon">
                  {entry.harness ? (
                    <AgentMark
                      agent={entry.harness}
                      size={ROW_ICON}
                      fallback={<TonedIcon name="agent.chat" size={ROW_ICON} tone={agentTone(entry.sessionId)} row />}
                    />
                  ) : (
                    <TonedIcon name="agent.chat" size={ROW_ICON} tone={agentTone(entry.sessionId)} row />
                  )}
                </span>
              );
              const body = (
                <>
                  {mark}
                  <span className="acpmux-chat-inspector-row__name">{title}</span>
                  {place && <span className="acpmux-chat-inspector-row__detail">{place}</span>}
                  <span className="acpmux-chat-inspector-row__end acpmux-chat-inspector-usage__value">
                    {sortValue(stats, sort, locale)}
                  </span>
                </>
              );
              const current = entry.sessionId === chatId || undefined;
              return (
                <li key={entry.sessionId} data-current={current}>
                  {onOpen && !current ? (
                    <button
                      type="button"
                      className="acpmux-chat-inspector-row acpmux-chat-inspector-row--button"
                      onClick={() => onOpen(entry.sessionId)}
                    >
                      {body}
                    </button>
                  ) : (
                    <div className="acpmux-chat-inspector-row">{body}</div>
                  )}
                </li>
              );
            })}
          </ul>
          {folds && (
            <button
              type="button"
              className="acpmux-chat-inspector-fold acpmux-chat-inspector-usage-fold"
              aria-expanded={expanded}
              onClick={() => setExpanded(!expanded)}
            >
              {expanded ? t("summary.showFewer") : t("summary.viewAll", { n: ranked.length })}
            </button>
          )}
        </>
      )}
    </div>
  );
}
