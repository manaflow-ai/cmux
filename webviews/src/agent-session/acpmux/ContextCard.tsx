// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own). A harness with no
// breakdown gets Codex's compact three-line tooltip; Claude's reported breakdown keeps the richer
// card with its stacked bar and Details link. Both use the shared glass hover card (.ui-card.ui-glass).
import "./contextCard.css";

import { useT } from "./i18n";
import { contextBreakdown, type Breakdown } from "./session-info/contextSectionModel";
import { compactBreakdownRows, CACHE_SOON_MS, cacheTimeLeft, useCacheTimeLeft } from "./contextCardModel";
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
