// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own). A harness with no
// breakdown gets Codex's compact three-line tooltip; Claude's reported breakdown keeps the richer
// card with its stacked bar and Details link. Both use the shared glass hover card (.ui-card.ui-glass).
import "./contextCard.css";
import { useT } from "./i18n";
import { contextBreakdown, type Breakdown, type BreakdownRow } from "./inspector/ContextSection";

/// One stretch of the stacked bar, as a share of the whole window (0-100).
export type ContextSegment = {
  kind: "setup" | "conversation" | "used";
  tokens: number;
  percent: number;
};

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

type CompactBreakdownRow = { name: string; tokens: number; share: number; tone: number };

/**
 * Pick the three useful headline categories for the small composer card. The Inspector keeps the
 * complete `/context` report; the card only needs enough signal to answer what is using the window.
 */
export function compactBreakdownRows(breakdown: Breakdown): CompactBreakdownRow[] {
  const used = breakdown.rows.filter((row) => row.kind === "used");
  const grouped: Array<{ name: string; rows: BreakdownRow[] }> = [
    { name: "Messages", rows: used.filter((row) => /message/i.test(row.name)) },
    { name: "Tools", rows: used.filter((row) => /tool/i.test(row.name)) },
    {
      name: "System",
      rows: used.filter((row) => !/message|tool/i.test(row.name)),
    },
  ];
  const rows = grouped
    .filter((group) => group.rows.length > 0)
    .map((group, tone) => ({
      name: group.name,
      tokens: group.rows.reduce((sum, row) => sum + row.tokens, 0),
      share: group.rows.reduce((sum, row) => sum + (row.share ?? 0), 0),
      tone,
    }));
  if (rows.length > 0) return rows;
  return used.slice(0, 3).map((row, tone) => ({
    name: row.name,
    tokens: row.tokens,
    share: row.share ?? 0,
    tone,
  }));
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
  const tokens = new Intl.NumberFormat(undefined, {
    notation: "compact",
    maximumFractionDigits: 1,
  });
  const percent = Math.round(Math.min(1, Math.max(0, used / size)) * 100);
  const breakdown: Breakdown | undefined = contextBreakdown(reported);
  const compactRows = breakdown ? compactBreakdownRows(breakdown) : [];
  return (
    <>
      <div className="acpmux-context-card-title">{t("context.title")}</div>
      <div className="acpmux-context-card-line">
        <span className="acpmux-context-card-compact-tokens">
          {t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
        </span>
      </div>
      <progress
        className="acpmux-context-card-bar"
        aria-label={t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
        aria-valuetext={t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
        value={percent}
        max={100}
      />
      {compactRows.length > 0 && (
        <ul className="acpmux-context-card-parts">
          {compactRows.map((row) => (
            <li className="acpmux-context-card-part" key={row.name}>
              <span className="acpmux-context-card-swatch" data-tone={row.tone} aria-hidden="true" />
              <span>
                {row.name === "Tools"
                  ? t("chatInspector.context.mcpTools")
                  : row.name === "System"
                    ? t("context.setup")
                    : row.name}
              </span>
              <span className="acpmux-context-card-part-tokens">{tokens.format(row.tokens)}</span>
            </li>
          ))}
        </ul>
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
              <span aria-hidden="true">›</span>
            </button>
          )}
        </div>
      )}
    </>
  );
}
