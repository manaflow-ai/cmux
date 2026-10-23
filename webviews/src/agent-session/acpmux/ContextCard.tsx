// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own): "Context window",
// "23% used · 111k / 475k", the window as a thin stacked bar (the agent's setup, then the
// conversation, over the free track), the setup split when the chat reports it, Compact when the
// agent offers it, and "Details ›", which opens the Inspector at its Context section. It is the
// shared glass hover card (.ui-card.ui-glass), as a session's hover card is (contextCard.css).
import "./contextCard.css";
import { useT } from "./i18n";
import { ContextBreakdownView, contextBreakdown, type Breakdown } from "./inspector/ContextSection";

/// One stretch of the stacked bar, as a share of the whole window (0-100).
export type ContextSegment = { kind: "setup" | "conversation" | "used"; tokens: number; percent: number };

/// The bar's stretches: the agent's setup and the conversation when the setup is known (and
/// within what is used), else what is used as one. The rest of the track is free. Together they
/// never pass the whole track, even when a harness reports more used than its window.
export function contextSegments(used: number, size: number, setup?: number): ContextSegment[] {
  if (!(size > 0)) return [];
  const share = (tokens: number) => Math.max(0, (tokens / size) * 100);
  const parts: Array<Omit<ContextSegment, "percent">> =
    setup !== undefined && setup > 0 && setup <= used
      ? [
          { kind: "setup", tokens: setup },
          { kind: "conversation", tokens: used - setup },
        ]
      : [{ kind: "used", tokens: used }];
  let left = 100;
  return parts
    .filter((part) => part.tokens > 0)
    .map((part) => {
      const percent = Math.min(left, share(part.tokens));
      left -= percent;
      return { ...part, percent };
    });
}

export function ContextCardBody({
  used,
  size,
  setup,
  working,
  onCompact,
  onOpenDetails,
  breakdown: reported,
}: {
  used: number;
  size: number;
  setup?: number;
  working: boolean;
  onCompact?(): void;
  onOpenDetails?(): void;
  breakdown?: unknown;
}) {
  const t = useT();
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const percent = Math.round(Math.min(1, Math.max(0, used / size)) * 100);
  const segments = contextSegments(used, size, setup);
  const split = segments.length > 1 && setup !== undefined;
  const breakdown: Breakdown | undefined = contextBreakdown(reported);
  return (
    <>
      <div className="acpmux-context-card-title">{t("context.title")}</div>
      <div className="acpmux-context-card-line">
        {t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
      </div>
      {!breakdown && (
        <div className="acpmux-context-card-bar acpmux-context-bar" aria-hidden="true">
          {segments.map((segment) => (
            <span key={segment.kind} data-segment={segment.kind} style={{ width: `${segment.percent}%` }} />
          ))}
        </div>
      )}
      {breakdown && <ContextBreakdownView breakdown={breakdown} />}
      {!breakdown && split && (
        <div className="acpmux-context-card-parts">
          <div className="acpmux-context-card-part" data-segment="setup">
            <span className="acpmux-context-card-swatch" aria-hidden="true" />
            <span className="acpmux-context-card-part-name">{t("context.setup")}</span>
            <span className="acpmux-context-card-part-tokens">{tokens.format(setup)}</span>
          </div>
          <div className="acpmux-context-card-part" data-segment="conversation">
            <span className="acpmux-context-card-swatch" aria-hidden="true" />
            <span className="acpmux-context-card-part-name">{t("context.conversation")}</span>
            <span className="acpmux-context-card-part-tokens">{tokens.format(used - setup)}</span>
          </div>
        </div>
      )}
      {(onCompact || onOpenDetails) && (
        <div className="acpmux-context-card-foot">
          {onCompact && (
            <button type="button" className="acpmux-context-card-compact" disabled={working} onClick={onCompact}>
              {t("context.compact")}
            </button>
          )}
          {onOpenDetails && (
            <button type="button" className="acpmux-context-card-details" onClick={onOpenDetails}>
              {t("context.details")}
              <span aria-hidden="true"> ›</span>
            </button>
          )}
        </div>
      )}
    </>
  );
}
