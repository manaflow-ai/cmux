// The context ring's hover card (Leo 2026-10-21, after Claude's and Codex's own): "Context window",
// "23% used · 111k / 475k", the window as a thin stacked bar, a row per part of it as Claude Code's
// /context counts it (system, tools, files, messages; contextBreakdown.ts), the chat's model and
// its window, when the chat last compacted, "Compact now" when the agent offers /compact, and
// "Details ›", which opens the Inspector at its Context section. Each row shows only when the chat
// reported its data. It sits on the tooltip's frosted glass, as every link's hover card does
// (contextCard.css).
import "./contextCard.css";
import { age } from "./HomeLists";
import { contextParts, type ContextBreakdown, type ContextPartKind } from "./contextBreakdown";
import { useT, type StringKey } from "./i18n";

/// One stretch of the stacked bar, as a share of the whole window (0-100).
export type ContextSegment = {
  kind: "setup" | "conversation" | "used" | ContextPartKind;
  tokens: number;
  percent: number;
};

const PART_LABELS: Record<ContextPartKind, StringKey> = {
  system: "context.system",
  tools: "context.tools",
  files: "context.files",
  messages: "context.messages",
};

/// The bar's stretches: Claude Code's breakdown when the chat reported one; else the agent's
/// setup and the conversation when the setup is known (and within what is used); else what is
/// used as one. The rest of the track is free.
export function contextSegments(
  used: number,
  size: number,
  setup?: number,
  breakdown?: ContextBreakdown,
): ContextSegment[] {
  if (!(size > 0)) return [];
  const share = (tokens: number) => Math.min(100, Math.max(0, (tokens / size) * 100));
  const parts = contextParts(used, breakdown);
  const stretches: Array<Omit<ContextSegment, "percent">> =
    parts.length > 0
      ? parts
      : setup !== undefined && setup > 0 && setup <= used
        ? [
            { kind: "setup", tokens: setup },
            { kind: "conversation", tokens: used - setup },
          ]
        : [{ kind: "used", tokens: used }];
  return stretches.filter((part) => part.tokens > 0).map((part) => ({ ...part, percent: share(part.tokens) }));
}

export function ContextCardBody({
  used,
  size,
  setup,
  breakdown,
  model,
  compactedAt,
  now = Date.now(),
  working,
  onCompact,
  onOpenDetails,
}: {
  used: number;
  size: number;
  setup?: number;
  /// Claude Code's /context rows (contextBreakdown.ts); none from Codex.
  breakdown?: ContextBreakdown;
  /// The chat's model, named as people say it ("Opus 5.5").
  model?: string;
  /// When the chat last finished a compaction (ms since the epoch), when one is in its history.
  compactedAt?: number;
  now?: number;
  working: boolean;
  onCompact?(): void;
  onOpenDetails?(): void;
}) {
  const t = useT();
  const tokens = new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 });
  const percent = Math.round(Math.min(1, Math.max(0, used / size)) * 100);
  const segments = contextSegments(used, size, setup, breakdown);
  const rows = segments.filter((segment) => segment.kind !== "used");
  const label = (kind: ContextSegment["kind"]) =>
    t(kind === "setup" ? "context.setup" : kind === "conversation" ? "context.conversation" : PART_LABELS[kind as ContextPartKind]);
  const compacted = compactedAt !== undefined ? age(compactedAt, now, t) : undefined;
  return (
    <>
      <div className="acpmux-context-card-title">{t("context.title")}</div>
      <div className="acpmux-context-card-line">
        {t("context.cardLine", { percent, used: tokens.format(used), size: tokens.format(size) })}
      </div>
      <div className="acpmux-context-card-bar" aria-hidden="true">
        {segments.map((segment) => (
          <span key={segment.kind} data-segment={segment.kind} style={{ width: `${segment.percent}%` }} />
        ))}
      </div>
      {rows.length > 0 && (
        <div className="acpmux-context-card-parts">
          {rows.map((row) => (
            <div key={row.kind} className="acpmux-context-card-part" data-segment={row.kind}>
              <span className="acpmux-context-card-swatch" aria-hidden="true" />
              <span className="acpmux-context-card-part-name">{label(row.kind)}</span>
              <span className="acpmux-context-card-part-tokens">{tokens.format(row.tokens)}</span>
            </div>
          ))}
        </div>
      )}
      {(model || compacted) && (
        <div className="acpmux-context-card-facts">
          {model && (
            <div className="acpmux-context-card-fact" data-fact="model">
              {t("context.modelWindow", { model, size: tokens.format(size) })}
            </div>
          )}
          {compacted && (
            <div className="acpmux-context-card-fact" data-fact="compacted">
              {t("context.compacted", { ago: compacted })}
            </div>
          )}
        </div>
      )}
      {(onCompact || onOpenDetails) && (
        <div className="acpmux-context-card-foot">
          {onCompact && (
            <button type="button" className="acpmux-context-card-compact" disabled={working} onClick={onCompact}>
              {t("context.compactNow")}
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
