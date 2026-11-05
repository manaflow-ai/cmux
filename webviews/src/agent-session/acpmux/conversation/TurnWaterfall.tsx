// A finished turn's Timeline: each timed tool call and thought as a bar on one time axis from the
// turn's start, so a slow turn shows where its time went (Leo, 2026-11-05: "Build all four and more
// and keep thinking of more interesting/useful things"). The footer's clock button opens it; closed,
// as every footer starts, nothing is drawn or computed. A call's bar opens that call's row
// (TurnActions `showCall`, App.tsx `showToolRow`), as a running line's count does.
import { useContext, useId, useMemo, useState, type CSSProperties, type ReactNode } from "react";
import type { Translate } from "../i18n";
import { useT } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolLabel } from "../toolPaths";
import { Clock } from "./icons";
import { ROW_ICON } from "./MessageActions";
import { TurnActionsContext } from "./turnActions";
import { waterfall, WATERFALL_FIRST, type WaterfallSpan, type WaterfallTone } from "./waterfallSpans";
import "./TurnWaterfall.css";

/// How the bars lay out: `bars` (label, then its bar on the shared axis), `stacked` (the label over
/// a full-width bar) or `lanes` (one lane per kind of work, its bars side by side).
export type WaterfallLook = "bars" | "stacked" | "lanes";

/// A lane's name in the `lanes` look.
const LANE_NAMES = {
  shell: "turn.timeline.kind.shell",
  read: "turn.timeline.kind.read",
  edit: "turn.timeline.kind.edit",
  web: "turn.timeline.kind.web",
  other: "turn.timeline.kind.other",
  thought: "turn.timeline.thought",
} as const;

/// "840ms", "4.2s", "2m 5s", as a call row's own time (toolGroups.ts toolDuration).
export function spanTime(t: Translate, ms: number): string {
  if (ms < 1000) return t("duration.ms", { n: Math.round(ms) });
  if (ms < 60_000) return t("duration.s", { n: (ms / 1000).toFixed(1) });
  const seconds = Math.round(ms / 1000);
  return t("duration.m", { m: Math.floor(seconds / 60), s: seconds % 60 });
}

function spanLabel(t: Translate, item: AcpmuxActivity): string {
  if (!item.tool) return t("turn.timeline.thought");
  return toolLabel(
    item.tool,
    item.text,
    (command) => t("tools.ranCommand", { command }),
    undefined,
    t("tools.ranUnnamed"),
  );
}

/// The footer's Timeline toggle and, while it is open, the waterfall under the footer row. Null for
/// a footer whose turn timed no call.
export function useTurnWaterfall(row: AcpmuxRow, look: WaterfallLook = "bars"): { toggle: ReactNode; panel: ReactNode } {
  const t = useT();
  const [open, setOpen] = useState(false);
  const id = useId();
  if (!row.turnWork?.length) return { toggle: null, panel: null };
  const label = open ? t("turn.timeline.hide") : t("turn.timeline.show");
  return {
    toggle: (
      <button
        type="button"
        className={`cv-iconbtn cv-iconbtn--compact cv-waterfall-toggle${open ? " is-open" : ""}`}
        aria-label={label}
        title={label}
        aria-expanded={open}
        aria-controls={open ? id : undefined}
        onClick={() => setOpen((now) => !now)}
      >
        <Clock size={ROW_ICON} />
      </button>
    ),
    panel: open ? <TurnWaterfall id={id} row={row} work={row.turnWork} look={look} /> : null,
  };
}

export function TurnWaterfall({
  id,
  row,
  work,
  look = "bars",
}: {
  id?: string;
  row: Pick<AcpmuxRow, "at" | "durationMs">;
  work: readonly AcpmuxActivity[];
  look?: WaterfallLook;
}) {
  const t = useT();
  const { showCall } = useContext(TurnActionsContext);
  const chart = useMemo(() => waterfall(row, work), [row, work]);
  const [all, setAll] = useState(false);
  const shown = all || look === "lanes" ? chart.spans : chart.spans.slice(0, WATERFALL_FIRST);
  const rest = chart.spans.length - shown.length;
  const slowest = chart.slowest === undefined ? undefined : chart.spans[chart.slowest];
  const place = (span: WaterfallSpan): CSSProperties =>
    ({
      "--wf-from": `${(span.from / chart.total) * 100}%`,
      "--wf-width": `${((span.to - span.from) / chart.total) * 100}%`,
    }) as CSSProperties;
  const bar = (span: WaterfallSpan, at: number, withLabel: boolean) => {
    const label = spanLabel(t, span.item);
    const time = spanTime(t, span.to - span.from);
    const isSlowest = span === slowest;
    const className = [
      "cv-waterfall__span",
      `is-${span.tone}`,
      span.failed && "is-failed",
      isSlowest && "is-slowest",
      span.toolId && showCall && "is-link",
    ]
      .filter(Boolean)
      .join(" ");
    const title = [label, time, span.failed && t("turn.timeline.failed"), isSlowest && t("turn.timeline.slowest")]
      .filter(Boolean)
      .join(" · ");
    const body = (
      <>
        {withLabel && (
          <span className="cv-waterfall__label">
            <span className="cv-waterfall__name">{label}</span>
            {span.failed && <span className="cv-waterfall__tag is-failed">{t("turn.timeline.failed")}</span>}
            {isSlowest && <span className="cv-waterfall__tag">{t("turn.timeline.slowest")}</span>}
          </span>
        )}
        <span className="cv-waterfall__track">
          <span className="cv-waterfall__bar" style={place(span)} />
        </span>
        {withLabel && <span className="cv-waterfall__time">{time}</span>}
      </>
    );
    const key = span.toolId ?? `thought:${at}`;
    return span.toolId && showCall ? (
      <li key={key}>
        <button
          type="button"
          className={className}
          title={title}
          data-tool-id={span.toolId}
          onClick={() => showCall(span.toolId!)}
        >
          {body}
        </button>
      </li>
    ) : (
      <li key={key}>
        <div className={className} title={title}>
          {body}
        </div>
      </li>
    );
  };
  // Lanes: one row per kind of work, in the order each kind first ran.
  const lanes = useMemo(() => {
    if (look !== "lanes") return [];
    const byTone = new Map<WaterfallTone, WaterfallSpan[]>();
    for (const span of chart.spans) byTone.set(span.tone, [...(byTone.get(span.tone) ?? []), span]);
    return [...byTone];
  }, [look, chart]);
  return (
    <section id={id} className={`cv-waterfall is-${look}`} aria-label={t("turn.timeline.label")} data-find-skip="">
      <div className="cv-waterfall__axis" aria-hidden="true">
        <span>{spanTime(t, 0)}</span>
        <span>{spanTime(t, chart.total / 2)}</span>
        <span>{spanTime(t, chart.total)}</span>
      </div>
      {look === "lanes" ? (
        <ul className="cv-waterfall__rows">
          {lanes.map(([tone, spans]) => (
            <li key={tone} className="cv-waterfall__lane">
              <span className="cv-waterfall__label">
                <span className="cv-waterfall__name">{t(LANE_NAMES[tone])}</span>
              </span>
              <span className="cv-waterfall__track">
                {spans.map((span) => (
                  <span
                    key={span.toolId ?? `${span.from}`}
                    className={`cv-waterfall__bar is-${span.tone}${span.failed ? " is-failed" : ""}${span === slowest ? " is-slowest" : ""}`}
                    style={place(span)}
                    title={`${spanLabel(t, span.item)} · ${spanTime(t, span.to - span.from)}`}
                  />
                ))}
              </span>
              <span className="cv-waterfall__time">{spans.length}</span>
            </li>
          ))}
        </ul>
      ) : (
        <ol className="cv-waterfall__rows">{shown.map((span, at) => bar(span, at, true))}</ol>
      )}
      {rest > 0 && (
        <button type="button" className="cv-waterfall__more" onClick={() => setAll(true)}>
          {t("turn.timeline.more", { n: rest })}
        </button>
      )}
    </section>
  );
}
