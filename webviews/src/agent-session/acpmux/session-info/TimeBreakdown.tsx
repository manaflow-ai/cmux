import { memo } from "react";
import { useT } from "../i18n";
import type { AcpmuxTimeBreakdown, AcpmuxTimeSpan } from "../model";
import "./TimeBreakdown.css";

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
  const spans = (Array.isArray(breakdown.spans) ? breakdown.spans : [])
    .filter((span) => Number.isFinite(span.startAt) && Number.isFinite(span.endAt) && span.endAt >= span.startAt)
    .slice(-128);
  const categories = (Array.isArray(breakdown.categories) ? breakdown.categories : []).filter(
    (category) => Number.isFinite(category.wallMs) && category.wallMs > 0,
  );
  if (!spans.length && !categories.length) return null;
  const totalMs = Number.isFinite(breakdown.totalMs) ? Math.max(0, breakdown.totalMs) : 0;
  const maxMs = Math.max(1, ...spans.map((span) => span.endAt - span.startAt));
  const label = (id: string) => (LABEL_KEYS[id] ? t(LABEL_KEYS[id]) : id);
  const spanButton = (span: AcpmuxTimeSpan, index: number) => {
    const ms = span.endAt - span.startAt;
    const title = t("timeBreakdown.span", {
      category: label(span.category),
      duration: duration(ms),
      turn: span.turnId ?? "—",
    });
    return (
      <button
        key={`${span.turnSeq}:${span.startAt}:${index}`}
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
      />
    );
  };
  return (
    <section className="acpmux-time-breakdown" data-look={look} aria-label={t("timeBreakdown.title")}>
      <div className="acpmux-time-breakdown__heading">
        <span>{t("timeBreakdown.title")}</span>
        <span className="acpmux-time-breakdown__total">
          {duration(totalMs)}
          {breakdown.totalTokens !== undefined &&
            ` · ${t("timeBreakdown.totalTokens", { tokens: tokens(breakdown.totalTokens) })}`}
        </span>
      </div>
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
                {category.tokens !== undefined && (
                  <span>
                    {tokens(category.tokens)} {t("timeBreakdown.tokensSuffix")}
                  </span>
                )}
                <span
                  className="acpmux-time-breakdown__total-bar"
                  style={{
                    width: `${Math.max(4, totalMs ? (category.wallMs / totalMs) * 100 : 4)}%`,
                    background: COLORS[category.id],
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
            {category.tokens !== undefined && ` · ${tokens(category.tokens)} ${t("timeBreakdown.tokensSuffix")}`}
          </span>
        ))}
      </div>
      {!breakdown.tokensComplete && (
        <small className="acpmux-time-breakdown__hint">{t("timeBreakdown.tokensPending")}</small>
      )}
      <span className="acpmux-time-breakdown__scale" aria-hidden="true">
        {maxMs > 1 ? t("timeBreakdown.recentTurns") : ""}
      </span>
    </section>
  );
});
