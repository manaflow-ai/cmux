// Session Info's Usage (SessionInfo.tsx), one row in the top block like Context: what this chat
// spent in the last 24 hours, and every session acpmux lists, this Mac's and its peers', sorted by
// 24h cost or by context, so the top spenders are one glance away. Leo, 2026-10-30: "that
// visibility into huge-blue guys was (and is?) pretty bad i feel like we can make more improvements
// to acpmux/cmux-next". The numbers are acpmux's `usageStats` (usageStats.ts), refreshed on the
// session list acpmux already sends; the list is sorted only while the section is open, and only
// when the list or the sort changes.
import { memo, useMemo, useState } from "react";
import { useT, type Translate } from "../i18n";
import { AgentMark } from "../../shared/AgentMark";
import { agentTone } from "../subagents/agentTones";
import { TonedIcon } from "../subagents/TonedIcon";
import { rowIconSize } from "../icons/iconSize";
import type { AcpmuxSessionEntry } from "../sessionList";
import { byUsage, type SessionUsageStats, UNKNOWN, type UsageSort, usageCost, usageTokens } from "../usageStats";
import "./UsageSection.css";

const ROW_ICON = rowIconSize(12);
/// Rows the list shows before View all.
export const USAGE_SHOWN = 5;

/// The section's one-line value: this chat's 24h cost, else its 24h tokens.
export function usageMeta(t: Translate, stats: SessionUsageStats | undefined, locale?: string): string | undefined {
  if (!stats) return undefined;
  if (stats.costUsd24h !== undefined)
    return t("sessionInfo.usage.cost24hValue", { cost: usageCost(stats.costUsd24h, locale) });
  if (stats.tokens24h !== undefined)
    return t("sessionInfo.usage.tokens24hValue", { tokens: usageTokens(stats.tokens24h, locale) });
  return undefined;
}

/// What a row of this chat's numbers offers next (Leo's rule via acpmux-owner: every number has a
/// next step): Compact for the context, the Subagents section for its subagents, and a Restart
/// with an autocompact cap for an uncapped chat, shown disabled until acpmux can do it.
type OwnAction = "compact" | "subagents" | "cap";
type OwnRow = { id: string; name: string; value: string; action?: OwnAction };

/// `value` formatted, or the unknown mark: never a synthesized 0 or $0.00.
const known = <T,>(value: T | undefined, format: (value: T) => string) =>
  value === undefined ? UNKNOWN : format(value);

/// This chat's numbers, as name and value rows.
function ownRows(t: Translate, stats: SessionUsageStats, locale?: string): OwnRow[] {
  const tokens = (value: number) => usageTokens(value, locale);
  const subagents = [stats.subagentsLive, stats.subagents1h, stats.subagents24h];
  const rows: OwnRow[] = [
    {
      id: "cost",
      name: t("sessionInfo.usage.cost24h"),
      value: known(stats.costUsd24h, (cost) => usageCost(cost, locale)),
    },
    { id: "tokens", name: t("sessionInfo.usage.tokens24h"), value: known(stats.tokens24h, tokens) },
    {
      id: "context",
      name: t("sessionInfo.usage.perCall"),
      value:
        stats.contextTokens !== undefined && stats.contextWindow
          ? `${tokens(stats.contextTokens)} / ${tokens(stats.contextWindow)}`
          : known(stats.contextTokens, tokens),
      action: "compact",
    },
    {
      id: "cap",
      name: t("sessionInfo.usage.autocompact"),
      // Only acpmux's `none` is no cap; a cap it could not read is unknown, never "No cap".
      value:
        stats.autocompact === "none"
          ? t("sessionInfo.usage.noCap")
          : stats.autocompact === "capped"
            ? known(stats.autocompactCap, tokens)
            : UNKNOWN,
      ...(stats.autocompact === "none" && { action: "cap" as const }),
    },
    { id: "compactions", name: t("sessionInfo.usage.compactions24h"), value: known(stats.compactions24h, String) },
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
      action: "subagents",
    },
  ];
  if (stats.launcher) rows.push({ id: "launcher", name: t("sessionInfo.usage.launcher"), value: stats.launcher });
  return rows;
}

/// What a list row's end says for `sort`: the measure the list is sorted by, or the unknown mark.
/// A 24h cost acpmux could not read is the unknown mark, never a token count under a cost heading.
function sortValue(stats: SessionUsageStats, sort: UsageSort, locale?: string): string {
  if (sort === "cost") return known(stats.costUsd24h, (cost) => usageCost(cost, locale));
  return known(stats.contextTokens, (tokens) => usageTokens(tokens, locale));
}

/// Memoized: its props are the same objects until acpmux's numbers or list change (direct.ts keeps
/// both), so a snapshot per token draws none of its rows again.
export const UsageSection = memo(function UsageSection({
  own,
  sessions,
  chatId,
  onOpen,
  onCompact,
  onShowSubagents,
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
  /// Sends this chat's agent its `/compact` (App.tsx, as a context-full failure's Compact); without
  /// it (an agent that serves no /compact, a View Only chat) Compact is not offered.
  onCompact?: () => void;
  /// Opens and shows the Subagents section; without it (no Subagents section) nothing is offered.
  onShowSubagents?: () => void;
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
    <div className="acpmux-session-info-usage" data-section="usage">
      {own && (
        <ul className="acpmux-session-info-list">
          {ownRows(t, own, locale).map(({ id, name, value, action }) => (
            <li key={id} className="acpmux-session-info-row" data-usage={id}>
              <span className="acpmux-session-info-row__name">{name}</span>
              <span className="acpmux-session-info-row__end acpmux-session-info-usage__value">{value}</span>
              {action === "compact" && onCompact && (
                <button type="button" className="acpmux-session-info-usage__action" onClick={onCompact}>
                  {t("context.compact")}
                </button>
              )}
              {action === "subagents" && onShowSubagents && (
                <button type="button" className="acpmux-session-info-usage__action" onClick={onShowSubagents}>
                  {t("sessionInfo.usage.showSubagents")}
                </button>
              )}
              {/* acpmux cannot restart a session with a cap yet: the step is named, not invented. */}
              {action === "cap" && (
                <button
                  type="button"
                  className="acpmux-session-info-usage__action"
                  disabled
                  title={t("sessionInfo.usage.restartWithCapSoon")}
                >
                  {t("sessionInfo.usage.restartWithCap")}
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
      {ranked.length > 0 && (
        <>
          <div className="acpmux-session-info-usage__head">
            <span className="acpmux-session-info-usage__title">{t("sessionInfo.usage.allSessions")}</span>
            <fieldset className="acpmux-session-info-usage__sort" aria-label={t("sessionInfo.usage.sortBy")}>
              {(["cost", "context"] as const).map((option) => (
                <button
                  key={option}
                  type="button"
                  className="acpmux-session-info-usage__sort-option"
                  aria-pressed={sort === option}
                  // The pressed option is the order shown: a click on it would do nothing.
                  disabled={sort === option}
                  onClick={() => setSort(option)}
                >
                  {t(option === "cost" ? "sessionInfo.usage.sortCost" : "sessionInfo.usage.sortContext")}
                </button>
              ))}
            </fieldset>
          </div>
          <ul className="acpmux-session-info-list" data-sort={sort}>
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
                  <span className="acpmux-session-info-row__name">{title}</span>
                  {place && <span className="acpmux-session-info-row__detail">{place}</span>}
                  <span className="acpmux-session-info-row__end acpmux-session-info-usage__value">
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
                      className="acpmux-session-info-row acpmux-session-info-row--button"
                      onClick={() => onOpen(entry.sessionId)}
                    >
                      {body}
                    </button>
                  ) : (
                    <div className="acpmux-session-info-row">{body}</div>
                  )}
                </li>
              );
            })}
          </ul>
          {folds && (
            <button
              type="button"
              className="acpmux-session-info-fold acpmux-session-info-usage-fold"
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
});
