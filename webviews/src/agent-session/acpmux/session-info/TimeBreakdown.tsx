import { memo } from "react";
import type { AcpmuxTimeBreakdown, AcpmuxTimeSpan } from "../model";
import "./TimeBreakdown.css";

const COLORS: Record<string, string> = {
  read: "var(--agent-blue, #6ca8ff)",
  edit: "var(--agent-green, #70c58c)",
  run: "var(--agent-orange, #e5a35b)",
  think: "var(--agent-purple, #b18cff)",
  person: "var(--agent-yellow, #e7c96b)",
  model: "var(--agent-muted, #8d96a5)",
};
const LABELS: Record<string, string> = {
  read: "Reading",
  edit: "Editing",
  run: "Commands",
  think: "Thinking",
  person: "You",
  model: "Model",
};

function duration(ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.floor((ms % 60_000) / 1_000);
  return minutes ? `${minutes}m ${seconds}s` : `${seconds}s`;
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
  const spans = breakdown.spans.filter((span) => span.endAt >= span.startAt);
  if (
    !spans.length &&
    !breakdown.categories.some((category) => category.wallMs > 0)
  )
    return null;
  const maxMs = Math.max(1, ...spans.map((span) => span.endAt - span.startAt));
  const categories = breakdown.categories.filter(
    (category) => category.wallMs > 0,
  );
  const spanButton = (span: AcpmuxTimeSpan, index: number) => {
    const ms = span.endAt - span.startAt;
    const title = `${LABELS[span.category] ?? span.category} · ${duration(ms)}${span.turnId ? ` · turn ${span.turnId}` : ""}`;
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
    <section
      className="acpmux-time-breakdown"
      data-look={look}
      aria-label="Where the time went"
    >
      <div className="acpmux-time-breakdown__heading">
        <span>Where the time went</span>
        <span className="acpmux-time-breakdown__total">
          {duration(breakdown.totalMs)}
        </span>
      </div>
      {look === "stacked" && (
        <div className="acpmux-time-breakdown__stack">
          {spans.map(spanButton)}
        </div>
      )}
      {look === "lanes" && (
        <div className="acpmux-time-breakdown__lanes">
          {categories.map((category) => (
            <div className="acpmux-time-breakdown__lane" key={category.id}>
              <span>{LABELS[category.id] ?? category.id}</span>
              <div className="acpmux-time-breakdown__lane-bars">
                {spans
                  .filter((span) => span.category === category.id)
                  .map(spanButton)}
              </div>
            </div>
          ))}
        </div>
      )}
      {look === "totals" && (
        <div className="acpmux-time-breakdown__totals">
          {categories.map((category) => (
            <div className="acpmux-time-breakdown__total-row" key={category.id}>
              <span>{LABELS[category.id] ?? category.id}</span>
              <span>{duration(category.wallMs)}</span>
              <span
                className="acpmux-time-breakdown__total-bar"
                style={{
                  width: `${Math.max(4, (category.wallMs / breakdown.totalMs) * 100)}%`,
                  background: COLORS[category.id],
                }}
              />
            </div>
          ))}
        </div>
      )}
      <div className="acpmux-time-breakdown__legend">
        {categories.map((category) => (
          <span key={category.id}>
            <i style={{ background: COLORS[category.id] }} />
            {LABELS[category.id] ?? category.id}
          </span>
        ))}
      </div>
      {!breakdown.tokensComplete && (
        <small className="acpmux-time-breakdown__hint">
          Token totals update when a turn reports usage.
        </small>
      )}
      <span className="acpmux-time-breakdown__scale" aria-hidden="true">
        {maxMs > 1 ? "Recent turns" : ""}
      </span>
    </section>
  );
});
