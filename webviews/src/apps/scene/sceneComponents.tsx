// The finished components' variants and states, and the Stat and Chart nodes (RFD 0009 slice 4).
// The contract is the Rust design check's table (cmux-tui src/cli/ext/design_components.rs); the
// AppKit twin is AppSceneComponentState.swift with AppSceneStatNSView and AppSceneChartNSView.
import type { ReactNode } from "react";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { SceneSymbol } from "./SceneSymbol";
import { sceneColor, sceneText } from "./sceneStyle";

/** The nodes that take `.variant(...)` and `.state(...)`. */
export const FINISHED_COMPONENTS: ReadonlySet<string> = new Set([
  "Row",
  "Badge",
  "Button",
  "ProgressView",
  "Stat",
  "Chart",
  "Toggle",
  "Slider",
  "TextField",
  "Image",
  "EmptyState",
]);

/** The ones that draw more than `standard`. */
const VARIANT_COMPONENTS: ReadonlySet<string> = new Set(["Row", "Badge", "Button", "ProgressView", "Stat", "Chart"]);

export type SceneComponentVariant = "standard" | "prominent" | "subtle";
export type SceneComponentState = "loading" | "error" | "empty";

/** The variant `type` draws for `value`: `standard` for anything else. */
export function componentVariant(type: string, value: unknown): SceneComponentVariant {
  if (!VARIANT_COMPONENTS.has(type)) return "standard";
  return value === "prominent" || value === "subtle" ? value : "standard";
}

/** The state the host draws in place of `type`, or undefined to draw the component. */
export function componentState(type: string, value: unknown): SceneComponentState | undefined {
  if (!FINISHED_COMPONENTS.has(type)) return undefined;
  return value === "loading" || value === "error" || value === "empty" ? value : undefined;
}

/** A state in place of a component: a 16 pt glyph (the spinner, a warning triangle in warning, a
 * tray in tertiary) and an optional one-line message in secondary. */
export function SceneComponentStateView({
  state,
  message,
  title,
}: {
  state: SceneComponentState;
  message: unknown;
  /** An EmptyState keeps its title under the state's glyph. */
  title?: unknown;
}) {
  const text = sceneText(message);
  const heading = sceneText(title);
  return (
    <>
      {state === "loading" ? (
        <Spinner loading size={16} />
      ) : (
        <SceneSymbol
          symbol={state === "error" ? "exclamationmark.triangle" : "tray"}
          size={16}
          color={sceneColor(state === "error" ? "warning" : "tertiary")}
        />
      )}
      {heading ? <strong>{heading}</strong> : null}
      {text ? <span className="cmux-app-scene-state-message">{text}</span> : null}
    </>
  );
}

/** The mark before a Stat's delta, the same text on AppKit (a glyph both fonts have). */
export const TREND_MARK = { up: "\u2191", down: "\u2193", flat: "" } as const;

/** The color of a Stat's delta: success when the trend is the good one, danger when it is not,
 * secondary when flat or unset. */
export function statDeltaColor(trend: unknown, goodTrend: unknown): "success" | "danger" | "secondary" {
  if (trend !== "up" && trend !== "down") return "secondary";
  const good = goodTrend === "down" ? "down" : "up";
  return trend === good ? "success" : "danger";
}

/** A Stat: the value in the numeral role, a caption under it and an optional delta with its trend. */
export function SceneStat({ props }: { props: Record<string, unknown> }): ReactNode {
  const label = sceneText(props.label);
  const delta = sceneText(props.delta);
  const trend = props.trend === "up" || props.trend === "down" || props.trend === "flat" ? props.trend : undefined;
  const tone = statDeltaColor(trend, props.goodTrend);
  return (
    <>
      <span className="cmux-app-scene-stat-value">{sceneText(props.value)}</span>
      {label || delta ? (
        <span className="cmux-app-scene-stat-caption">
          {label ? <span className="cmux-app-scene-stat-label">{label}</span> : null}
          {delta ? (
            <span className="cmux-app-scene-stat-delta" style={{ color: sceneColor(tone) }}>
              {trend && TREND_MARK[trend] ? `${TREND_MARK[trend]}\u2009${delta}` : delta}
            </span>
          ) : null}
        </span>
      ) : null}
    </>
  );
}

/** The most values a Chart draws (view.ts `CHART_MAX_VALUES`); the last ones. */
export const CHART_MAX_VALUES = 64;
/** A Chart's height when no frame sets one, and its line's width. */
export const CHART_HEIGHT = 32;
export const CHART_LINE_WIDTH = 1.5;
/** The gap between bars, as a fraction of each bar's slot. */
const BAR_GAP = 0.2;

export type ChartGeometry =
  | { kind: "line"; points: Array<[number, number]> }
  | { kind: "bar"; bars: Array<{ x: number; y: number; width: number; height: number }> };

/** Finite numbers, the last `CHART_MAX_VALUES` of them. */
export function chartValues(value: unknown): number[] {
  if (!Array.isArray(value)) return [];
  return value.filter((v): v is number => typeof v === "number" && Number.isFinite(v)).slice(-CHART_MAX_VALUES);
}

/**
 * Where a chart's marks go in a `width` by `height` box, y down. A line spans the values' range
 * (a flat series runs across the middle; one value is a flat line), inset by half its width so the
 * stroke is not clipped. Bars stand on zero: they rise above it and hang below it, and the range
 * always holds zero. The same arithmetic as AppSceneChartNSView.geometry.
 */
export function chartGeometry(
  values: readonly number[],
  kind: "line" | "bar",
  width: number,
  height: number,
): ChartGeometry {
  if (kind === "bar") {
    const lo = Math.min(0, ...values);
    const hi = Math.max(0, ...values);
    const span = hi - lo || 1;
    const y = (v: number) => height - ((v - lo) / span) * height;
    const slot = values.length ? width / values.length : 0;
    const barWidth = slot * (1 - BAR_GAP);
    const zero = y(0);
    return {
      kind,
      bars: values.map((v, i) => {
        const top = Math.min(y(v), zero);
        return { x: i * slot + (slot - barWidth) / 2, y: top, width: barWidth, height: Math.abs(y(v) - zero) };
      }),
    };
  }
  const inset = CHART_LINE_WIDTH / 2;
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const inner = height - 2 * inset;
  const y = (v: number) => (hi === lo ? height / 2 : inset + inner - ((v - lo) / (hi - lo)) * inner);
  if (values.length === 1)
    return {
      kind,
      points: [
        [0, y(values[0]!)],
        [width, y(values[0]!)],
      ],
    };
  const step = values.length > 1 ? width / (values.length - 1) : 0;
  return { kind, points: values.map((v, i) => [i * step, y(v)]) };
}

/** The width the chart's SVG coordinates use; it scales to the node's width. */
const CHART_VIEW_WIDTH = 100;

/** A Chart: a sparkline or bars from its values, in `color` (accent by default; secondary when
 * subtle), the line thicker with a soft fill under it when prominent. */
export function SceneChart({ props, variant }: { props: Record<string, unknown>; variant: SceneComponentVariant }) {
  const values = chartValues(props.values);
  const kind = props.kind === "bar" ? "bar" : "line";
  const color = sceneColor(variant === "subtle" ? "secondary" : props.color) ?? sceneColor("accent");
  if (!values.length) return null;
  const geometry = chartGeometry(values, kind, CHART_VIEW_WIDTH, CHART_HEIGHT);
  return (
    <svg
      className="cmux-app-scene-chart-marks"
      viewBox={`0 0 ${CHART_VIEW_WIDTH} ${CHART_HEIGHT}`}
      preserveAspectRatio="none"
      style={{ color }}
    >
      <title>{`${kind} chart of ${values.length} values`}</title>
      {geometry.kind === "bar" ? (
        geometry.bars.map((bar, i) => <rect key={i} {...bar} fill="currentColor" />)
      ) : (
        <>
          {variant === "prominent" ? (
            <polygon
              points={`0,${CHART_HEIGHT} ${geometry.points.map(([x, y]) => `${x},${y}`).join(" ")} ${CHART_VIEW_WIDTH},${CHART_HEIGHT}`}
              fill="currentColor"
              fillOpacity={0.14}
            />
          ) : null}
          <polyline
            points={geometry.points.map(([x, y]) => `${x},${y}`).join(" ")}
            fill="none"
            stroke="currentColor"
            strokeWidth={variant === "prominent" ? 2 : CHART_LINE_WIDTH}
            strokeLinejoin="round"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
          />
        </>
      )}
    </svg>
  );
}
