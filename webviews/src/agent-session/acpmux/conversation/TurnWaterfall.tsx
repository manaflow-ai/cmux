// A finished turn's Timeline: each timed tool call and thought as a bar on one time axis from the
// turn's start, so a slow turn shows where its time went (Leo, 2026-11-05: "Build all four and more
// and keep thinking of more interesting/useful things"). The footer's clock button opens it; closed,
// as every footer starts, nothing is drawn or computed. A call's bar opens that call's row
// (TurnActions `showCall`, App.tsx `showToolRow`), as a running line's count does.
import { useContext, useMemo, useState, type CSSProperties } from "react";
import type { Translate } from "../i18n";
import { useT } from "../i18n";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { toolLabel } from "../toolPaths";
import { TurnActionsContext } from "./turnActions";
import { waterfall, WATERFALL_FIRST, type WaterfallSpan, type WaterfallTone } from "./waterfallSpans";
import "./TurnWaterfall.css";
import { spanTime } from "./turnWaterfallModel";

/// How the bars lay out: `bars` (label, then its bar on the shared axis), `stacked` (the label over
/// a full-width bar) or `lanes` (one lane per kind of work, its bars side by side).
export type WaterfallLook = "bars" | "stacked" | "lanes";

/// What the header row's corner, left of the axis, says (Leo, 2026-11-07: "The top left, there's
/// nothing. So you might as well just show that it's, like, okay, this is the total time taken for
/// this turn"): `count` ("3 commands · 1m 30s", chosen), `total` ("1m 30s total"), `turn` ("Turn ·
/// 1m 30s") or `strong` (the count, then the total in full ink). The others are gallery arms.
export type WaterfallSummary = "count" | "total" | "turn" | "strong";

/// How the turn's time outside every call and thought shows, so the axis's total adds up (Leo,
/// 2026-11-05: "im not sure what the total thing is meant to represent. the total time of a turn?"):
/// `row` (a last row of its own, its bars in the gaps and its sum, chosen), `tint` (the gaps shaded
/// in every track, no row) or `none` (as before: blank track). The others are gallery arms.
export type WaterfallModelTime = "row" | "tint" | "none";

/// A gap shorter than this share of the axis draws no row: a turn of back-to-back calls has nothing
/// to explain.
const MODEL_TIME_MIN = 0.01;

/// A lane's name in the `lanes` look.
const LANE_NAMES = {
  shell: "turn.timeline.kind.shell",
  read: "turn.timeline.kind.read",
  edit: "turn.timeline.kind.edit",
  web: "turn.timeline.kind.web",
  other: "turn.timeline.kind.other",
  thought: "turn.timeline.thought",
} as const;

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

/// The header corner's words: how many calls the turn timed (commands when every one was a shell
/// command), then its total in the axis's own format. A turn that only thought says its total.
function summaryParts(
  t: Translate,
  spans: readonly WaterfallSpan[],
  total: number,
  summary: WaterfallSummary,
): { lead?: string; time: string } {
  const time = spanTime(t, total);
  if (summary === "total") return { time: t("turn.timeline.summary.total", { time }) };
  if (summary === "turn") return { lead: t("turn.timeline.summary.turn"), time };
  const calls = spans.filter((span) => span.item.tool);
  if (!calls.length) return { time };
  const commands = calls.every((span) => span.tone === "shell");
  return {
    lead: t(commands ? "turn.timeline.summary.commands" : "turn.timeline.summary.calls", { n: calls.length }),
    time,
  };
}

export function TurnWaterfall({
  id,
  row,
  work,
  look = "bars",
  summary = "count",
  modelTime = "row",
}: {
  id?: string;
  row: Pick<AcpmuxRow, "at" | "durationMs" | "workEndedAt">;
  work: readonly AcpmuxActivity[];
  look?: WaterfallLook;
  summary?: WaterfallSummary;
  modelTime?: WaterfallModelTime;
}) {
  const t = useT();
  const { showCall } = useContext(TurnActionsContext);
  const chart = useMemo(() => waterfall(row, work), [row, work]);
  const [all, setAll] = useState(false);
  const shown = all || look === "lanes" ? chart.spans : chart.spans.slice(0, WATERFALL_FIRST);
  const rest = chart.spans.length - shown.length;
  const corner = summaryParts(t, chart.spans, chart.total, summary);
  const slowest = chart.slowest === undefined ? undefined : chart.spans[chart.slowest];
  const gapsShown = modelTime !== "none" && chart.gapTotal >= chart.total * MODEL_TIME_MIN;
  const modelLabel = t("turn.timeline.model");
  const modelTitle = `${modelLabel} · ${spanTime(t, chart.gapTotal)}`;
  const place = (span: Pick<WaterfallSpan, "from" | "to">): CSSProperties =>
    ({
      "--wf-from": `${(span.from / chart.total) * 100}%`,
      "--wf-width": `${((span.to - span.from) / chart.total) * 100}%`,
    }) as CSSProperties;
  // The gaps' bars: the model row's own, or a shade behind each call's bar in the `tint` arm.
  const gapBars = (className: string) =>
    chart.gaps.map((gap) => <span key={gap.from} className={className} style={place(gap)} />);
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
          {gapsShown && modelTime === "tint" && gapBars("cv-waterfall__gap")}
          <span className="cv-waterfall__bar" style={place(span)} />
        </span>
        {withLabel && <span className="cv-waterfall__time">{time}</span>}
      </>
    );
    // A harness may reuse a call id, so the span's place keys it.
    const key = `${at}:${span.toolId ?? "thought"}`;
    return span.toolId && showCall ? (
      <li key={key}>
        <button
          type="button"
          className={className}
          title={title}
          data-tool-id={span.toolId}
          onClick={() => showCall(span.toolId!, span.item.tool?.startedAt)}
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
  // The turn's time outside every call and thought, last, so the rows above and it fill the axis.
  const modelRow = (
    <li key="model">
      <div className="cv-waterfall__span is-model" title={modelTitle}>
        <span className="cv-waterfall__label">
          <span className="cv-waterfall__name">{modelLabel}</span>
        </span>
        <span className="cv-waterfall__track">{gapBars("cv-waterfall__bar")}</span>
        <span className="cv-waterfall__time">{spanTime(t, chart.gapTotal)}</span>
      </div>
    </li>
  );
  // Lanes: one row per kind of work, in the order each kind first ran.
  const lanes = useMemo(() => {
    if (look !== "lanes") return [];
    const byTone = new Map<WaterfallTone, WaterfallSpan[]>();
    for (const span of chart.spans) byTone.set(span.tone, [...(byTone.get(span.tone) ?? []), span]);
    return [...byTone];
  }, [look, chart]);
  return (
    <section id={id} className={`cv-waterfall is-${look}`} aria-label={t("turn.timeline.label")} data-find-skip="">
      <div className="cv-waterfall__head">
        <span className={`cv-waterfall__summary${summary === "strong" ? " is-strong" : ""}`}>
          {corner.lead && <span>{corner.lead}</span>}
          {corner.lead && <span aria-hidden="true">{" · "}</span>}
          <span className="cv-waterfall__total">{corner.time}</span>
        </span>
        <div className="cv-waterfall__axis" aria-hidden="true">
          {/* The axis's start is the turn's start, not a duration: a bare 0, never "0ms". */}
          <span>0</span>
          <span>{spanTime(t, chart.total / 2)}</span>
          <span>{spanTime(t, chart.total)}</span>
        </div>
      </div>
      {look === "lanes" ? (
        <ul className="cv-waterfall__rows">
          {lanes.map(([tone, spans]) => (
            <li key={tone} className="cv-waterfall__lane">
              <span className="cv-waterfall__label">
                <span className="cv-waterfall__name">{t(LANE_NAMES[tone])}</span>
              </span>
              <span className="cv-waterfall__track">
                {spans.map((span, at) => (
                  <span
                    key={`${at}:${span.toolId ?? "thought"}`}
                    className={`cv-waterfall__bar is-${span.tone}${span.failed ? " is-failed" : ""}${span === slowest ? " is-slowest" : ""}`}
                    style={place(span)}
                    title={`${spanLabel(t, span.item)} · ${spanTime(t, span.to - span.from)}`}
                  />
                ))}
              </span>
              <span className="cv-waterfall__time">{spans.length}</span>
            </li>
          ))}
          {gapsShown && modelTime === "row" && modelRow}
        </ul>
      ) : (
        <ol className="cv-waterfall__rows">
          {shown.map((span, at) => bar(span, at, true))}
          {gapsShown && modelTime === "row" && modelRow}
        </ol>
      )}
      {rest > 0 && (
        <button type="button" className="cv-waterfall__more" onClick={() => setAll(true)}>
          {t("turn.timeline.more", { n: rest })}
        </button>
      )}
    </section>
  );
}
