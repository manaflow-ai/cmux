import { memo, useMemo, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxTimeBreakdown, AcpmuxTimeSpan } from "../model";
import "./TimeBreakdown.css";
import {
  hasUnknownCategoryTokens,
  normalizedTimeBreakdown,
  pageCount,
  timeSpanPage,
  turnTokenForSpan,
} from "./timeBreakdownModel";

const COLORS: Record<string, string> = {
  read: "color-mix(in srgb, var(--agent-text) 72%, var(--agent-muted))",
  edit: "color-mix(in srgb, var(--agent-text) 58%, var(--agent-muted))",
  run: "color-mix(in srgb, var(--agent-text) 44%, var(--agent-muted))",
  think: "color-mix(in srgb, var(--agent-text) 86%, var(--agent-muted))",
  person: "color-mix(in srgb, var(--agent-text) 30%, var(--agent-muted))",
  model: "var(--agent-muted)",
};
const LABEL_KEYS: Record<string, Parameters<ReturnType<typeof useT>>[0]> = {
  read: "timeBreakdown.read",
  edit: "timeBreakdown.edit",
  run: "timeBreakdown.run",
  think: "timeBreakdown.think",
  person: "timeBreakdown.person",
  model: "timeBreakdown.model",
};

function duration(ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.floor((ms % 60_000) / 1_000);
  return minutes ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

function tokens(value: number): string {
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

export type TimeBreakdownLook = "stacked" | "lanes" | "totals";

export const TimeBreakdown = memo(function TimeBreakdown({
  breakdown,
  onShowTurn,
  look = "stacked",
}: {
  breakdown: AcpmuxTimeBreakdown;
  onShowTurn?: (turnId: string) => void;
  look?: TimeBreakdownLook;
}) {
  const t = useT();
  const normalized = useMemo(() => normalizedTimeBreakdown(breakdown), [breakdown]);
  const [page, setPage] = useState(0);
  const pages = pageCount(normalized.spans.length);
  const safePage = Math.min(page, pages - 1);
  const spans = useMemo(() => timeSpanPage(normalized.spans, safePage), [normalized.spans, safePage]);
  const categories = normalized.categories;
  if (!spans.length && !categories.length) return null;
  const totalMs = normalized.totalMs;
  const label = (id: string) => (LABEL_KEYS[id] ? t(LABEL_KEYS[id]) : id);
  const spanButton = (span: AcpmuxTimeSpan, index: number) => {
    const ms = span.endAt - span.startAt;
    const turnTokens = turnTokenForSpan(span);
    const title =
      t("timeBreakdown.span", {
        category: label(span.category),
        duration: duration(ms),
        turn: span.turnSeq,
      }) + (turnTokens === undefined ? "" : ` · ${t("timeBreakdown.turnTokens", { tokens: tokens(turnTokens) })}`);
    return (
      <button
        key={`${span.turnSeq}:${span.turnId ?? ""}:${span.startAt}:${span.endAt}:${index}`}
        type="button"
        className="acpmux-time-breakdown__span"
        style={{
          background: COLORS[span.category] ?? COLORS.model,
          flexGrow: Math.max(1, ms),
        }}
        title={title}
        data-turn-seq={span.turnSeq}
        onClick={() => span.turnId && onShowTurn?.(span.turnId)}
        aria-label={title}
        disabled={!span.turnId || !onShowTurn}
      />
    );
  };
  return (
    <section className="acpmux-time-breakdown" data-look={look} aria-label={t("timeBreakdown.title")}>
      <div className="acpmux-time-breakdown__heading">
        <span>{t("timeBreakdown.title")}</span>
        <span className="acpmux-time-breakdown__total">
          {duration(totalMs)}
          {normalized.totalTokens !== undefined &&
            ` · ${t(normalized.tokensComplete ? "timeBreakdown.totalTokens" : "timeBreakdown.partialTokens", { tokens: tokens(normalized.totalTokens) })}`}
        </span>
      </div>
      <small className="acpmux-time-breakdown__hint">{t("timeBreakdown.recentTurns")}</small>
      {look === "stacked" && <div className="acpmux-time-breakdown__stack">{spans.map(spanButton)}</div>}
      {look === "lanes" && (
        <div className="acpmux-time-breakdown__lanes">
          {categories.map((category) => (
            <div className="acpmux-time-breakdown__lane" key={category.id}>
              <span>{label(category.id)}</span>
              <div className="acpmux-time-breakdown__lane-bars">
                {spans.filter((span) => span.category === category.id).map(spanButton)}
              </div>
            </div>
          ))}
        </div>
      )}
      {look === "totals" && (
        <div className="acpmux-time-breakdown__totals">
          {categories.map((category) => {
            const turnId = spans.find((span) => span.category === category.id)?.turnId;
            return (
              <button
                className="acpmux-time-breakdown__total-row"
                key={category.id}
                type="button"
                onClick={() => turnId && onShowTurn?.(turnId)}
                disabled={!turnId || !onShowTurn}
              >
                <span>{label(category.id)}</span>
                <span>{duration(category.wallMs)}</span>
                <span
                  className="acpmux-time-breakdown__total-bar"
                  style={{
                    width: `${Math.max(4, totalMs ? (category.wallMs / totalMs) * 100 : 4)}%`,
                    background: COLORS[category.id] ?? COLORS.model,
                  }}
                />
              </button>
            );
          })}
        </div>
      )}
      <div className="acpmux-time-breakdown__legend">
        {categories.map((category) => (
          <span key={category.id}>
            <i style={{ background: COLORS[category.id] }} />
            {label(category.id)} · {duration(category.wallMs)}
          </span>
        ))}
      </div>
      {hasUnknownCategoryTokens(normalized) && (
        <small className="acpmux-time-breakdown__hint">{t("timeBreakdown.tokensUnavailable")}</small>
      )}
      {pages > 1 && (
        <nav className="acpmux-time-breakdown__pager" aria-label={t("timeBreakdown.recentTurns")}>
          <button
            type="button"
            onClick={() => setPage((current) => Math.min(current + 1, pages - 1))}
            disabled={safePage >= pages - 1}
          >
            {t("timeBreakdown.previousPage")}
          </button>
          <span>{t("timeBreakdown.page", { page: safePage + 1, pages })}</span>
          <button
            type="button"
            onClick={() => setPage((current) => Math.max(current - 1, 0))}
            disabled={safePage === 0}
          >
            {t("timeBreakdown.nextPage")}
          </button>
        </nav>
      )}
    </section>
  );
});
