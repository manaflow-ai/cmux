// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own). A harness with no
// breakdown gets Codex's compact three-line tooltip; Claude's reported breakdown keeps the richer
// card with its stacked bar and Details link. Both use the shared glass hover card (.ui-card.ui-glass).
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
  const breakdown: Breakdown | undefined = contextBreakdown(reported);
  if (!breakdown) {
    return (
      <>
        <div className="acpmux-context-card-compact-content">
          <div className="acpmux-context-card-title">{t("context.title")}:</div>
          <div className="acpmux-context-card-compact-percent">{t("context.percent", { percent })}</div>
          <div className="acpmux-context-card-compact-tokens">
            {t("context.tokens", { used: tokens.format(used), size: tokens.format(size) })}
          </div>
        </div>
        {onOpenDetails && (
          <div className="acpmux-context-card-foot">
            <button type="button" className="acpmux-context-card-details" onClick={onOpenDetails}>
              {t("context.details")}
              <span aria-hidden="true"> ›</span>
            </button>
          </div>
        )}
      </>
    );
  }
  return (
    <>
      <div className="acpmux-context-card-title">{t("context.title")}</div>
      <div className="acpmux-context-card-line">
        {t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
      </div>
      <ContextBreakdownView breakdown={breakdown} />
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
