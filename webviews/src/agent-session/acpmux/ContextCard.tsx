// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own). A harness with no
// breakdown gets Codex's compact three-line tooltip; Claude's reported breakdown keeps the richer
// card with its stacked bar and Details link. Both use the shared glass hover card (.ui-card.ui-glass).
import "./contextCard.css";
import { useEffect, useState } from "react";
import { useT } from "./i18n";
import { contextBreakdown, type Breakdown, type BreakdownRow } from "./session-info/ContextSection";

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

/// `group`: one of the card's three headline groups, which the card names in the pane's language;
/// a row without one is the harness's own category, drawn under the name it reported.
type CompactGroup = "messages" | "tools" | "system";
type CompactBreakdownRow = { name: string; group?: CompactGroup; tokens: number; share: number; tone: number };

/**
 * Pick the three useful headline categories for the small composer card. Session Info keeps the
 * complete `/context` report; the card only needs enough signal to answer what is using the window.
 */
export function compactBreakdownRows(breakdown: Breakdown): CompactBreakdownRow[] {
  const used = breakdown.rows.filter((row) => row.kind === "used");
  const grouped: Array<{ group: CompactGroup; rows: BreakdownRow[] }> = [
    { group: "messages", rows: used.filter((row) => /message/i.test(row.name)) },
    { group: "tools", rows: used.filter((row) => /tool/i.test(row.name)) },
    { group: "system", rows: used.filter((row) => !/message|tool/i.test(row.name)) },
  ];
  const rows = grouped
    .filter((group) => group.rows.length > 0)
    .map((group, tone) => ({
      name: group.group,
      group: group.group,
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

/// Under this much left, the cache line says it is about to lapse.
export const CACHE_SOON_MS = 60_000;

/// "3:12", or "52:10" for an hour's cache: the time left, rounded up to the second.
export function cacheTimeLeft(ms: number): string {
  const seconds = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/// The time until `expiresAt` (unix ms), ticking each second while it is ahead. The tick stops at
/// the expiry, when `expiresAt` changes, and when the card unmounts. Undefined without an expiry.
export function useCacheTimeLeft(expiresAt: number | undefined, now: () => number = Date.now): number | undefined {
  const [at, setAt] = useState(now);
  useEffect(() => {
    if (expiresAt === undefined) return;
    setAt(now());
    if (expiresAt <= now()) return;
    const tick = window.setInterval(() => {
      const current = now();
      setAt(current);
      if (current >= expiresAt) window.clearInterval(tick);
    }, 1000);
    return () => window.clearInterval(tick);
  }, [expiresAt, now]);
  return expiresAt === undefined ? undefined : Math.max(0, expiresAt - at);
}

/// The prompt cache's line: a countdown while warm, then "Cache expired". acpmux sends the expiry
/// (claude_stdio/prompt_cache.rs) only for a harness that reports its cache and a known TTL.
function CacheLine({ expiresAt, now }: { expiresAt: number; now?: () => number }) {
  const t = useT();
  const left = useCacheTimeLeft(expiresAt, now) ?? 0;
  const state = left <= 0 ? "expired" : left <= CACHE_SOON_MS ? "soon" : "warm";
  return (
    <div className="acpmux-context-card-cache" data-state={state}>
      {state === "expired" ? t("context.cacheExpired") : t("context.cacheWarm", { left: cacheTimeLeft(left) })}
    </div>
  );
}

export function ContextCardBody({
  used,
  size,
  onOpenDetails,
  breakdown: reported,
  cacheExpiresAt,
  now,
}: {
  used: number;
  size: number;
  setup?: number;
  onOpenDetails?(): void;
  breakdown?: unknown;
  /// When the chat's prompt cache lapses (unix ms, from acpmux); no line without it.
  cacheExpiresAt?: number;
  /// The clock the countdown reads (the gallery pins it).
  now?: () => number;
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
      {/* The summary sits on the card's text inset; Details below runs edge to edge (contextCard.css). */}
      <div className="acpmux-context-card-body">
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
        {cacheExpiresAt !== undefined && <CacheLine expiresAt={cacheExpiresAt} now={now} />}
        {compactRows.length > 0 && (
          <ul className="acpmux-context-card-parts">
            {compactRows.map((row) => (
              <li className="acpmux-context-card-part" key={row.name}>
                <span className="acpmux-context-card-swatch" data-tone={row.tone} aria-hidden="true" />
                <span>
                  {row.group === "messages"
                    ? t("context.messages")
                    : row.group === "tools"
                      ? t("sessionInfo.context.mcpTools")
                      : row.group === "system"
                        ? t("context.setup")
                        : row.name}
                </span>
                <span className="acpmux-context-card-part-tokens">{tokens.format(row.tokens)}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
      {onOpenDetails && (
        <div className="acpmux-context-card-foot">
          <button type="button" className="acpmux-context-card-details" onClick={onOpenDetails}>
            {t("context.details")}
            {/* The composer's chevron-right path (ComposerPickers ChevronRightIcon), drawn as an icon so
                its box, not a font's › glyph, centres on the label. */}
            <svg
              className="acpmux-context-card-details-chevron"
              width={14}
              height={14}
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              strokeWidth={1.5}
              strokeLinecap="round"
              strokeLinejoin="round"
              aria-hidden="true"
              focusable="false"
            >
              <path d="m6.25 4.25 3.5 3.75-3.5 3.75" />
            </svg>
          </button>
        </div>
      )}
    </>
  );
}
