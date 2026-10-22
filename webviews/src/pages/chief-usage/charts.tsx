// The Chief Usage page's inline SVG charts (no chart library: the page stays small). Thin marks,
// recessive grid, tabular numbers, one accent per series from the page's chart tokens
// (styles.css), and a hover tooltip per bucket. Every design under designs/ draws from these.
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import {
  axisLabelIndexes,
  bandPath,
  bucketLabel,
  bucketTitle,
  formatMs,
  formatPercent,
  formatTokens,
  formatUSD,
  linePath,
  niceMax,
  scaleY,
  slotCenter,
  stackedBars,
  TOKEN_KINDS,
  type Plot,
  type TokenKind,
} from "./shape";
import type { UsageBucket, UsagePoint } from "./types";

/** The string key of each token kind's name. */
export const KIND_KEYS: Record<TokenKind, string> = {
  input: "chiefUsage.series.input",
  cache_read: "chiefUsage.series.cacheRead",
  cache_write: "chiefUsage.series.cacheWrite",
  output: "chiefUsage.series.output",
};

/** The width the chart's box has; 640 until measured (and in a DOM without ResizeObserver). */
function useWidth(fallback = 640) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(fallback);
  useLayoutEffect(() => {
    const node = ref.current;
    const Observer = node?.ownerDocument.defaultView?.ResizeObserver;
    if (!node || !Observer) return;
    const observer = new Observer(([entry]) => {
      const next = Math.round(entry?.contentRect.width ?? 0);
      if (next > 0) setWidth(next);
    });
    observer.observe(node);
    return () => observer.disconnect();
  }, []);
  return { ref, width };
}

interface TooltipRow {
  key: string;
  label: string;
  value: string;
  /** The series swatch class, when the row names a series. */
  swatch?: string;
}

/**
 * The chart box: the SVG, a transparent hit slot per bucket (wider than any mark) and the
 * tooltip of the hovered bucket.
 */
function ChartBox({
  label,
  height,
  count,
  plot,
  tooltip,
  className,
  children,
}: {
  label: string;
  height: number;
  count: number;
  plot: (width: number) => Plot;
  tooltip: (index: number) => { title: string; rows: TooltipRow[] };
  className?: string;
  children: (plot: Plot) => ReactNode;
}) {
  const { ref, width } = useWidth();
  const [hover, setHover] = useState<number | null>(null);
  const box = plot(width);
  const slot = (box.width - box.left - box.right) / Math.max(1, count);
  const tip = hover === null ? null : tooltip(hover);
  const center = hover === null ? 0 : slotCenter(hover, count, box);
  return (
    <div ref={ref} className={`cu-chart ${className ?? ""}`} onMouseLeave={() => setHover(null)}>
      <svg
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an inline SVG chart is one image with a label; an <img> cannot hold its hover targets.
        role="img"
        aria-label={label}
        width={box.width}
        height={height}
        viewBox={`0 0 ${box.width} ${height}`}
      >
        {hover !== null && (
          <rect
            className="cu-hover-slot"
            x={box.left + hover * slot}
            y={box.top}
            width={slot}
            height={height - box.top - box.bottom}
          />
        )}
        {children(box)}
        {Array.from({ length: count }, (_, index) => (
          <rect
            key={index}
            className="cu-hit"
            data-index={index}
            x={box.left + index * slot}
            y={0}
            width={slot}
            height={height}
            onMouseEnter={() => setHover(index)}
          />
        ))}
      </svg>
      {tip && (
        <div
          className={center > box.width / 2 ? "ui-glass cu-tooltip is-left" : "ui-glass cu-tooltip"}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the tooltip holds a <dl>, which an <output> (phrasing content only) may not contain.
          role="status"
          style={{ left: `${center}px` }}
        >
          <div className="cu-tooltip-title">{tip.title}</div>
          <dl>
            {tip.rows.map((row) => (
              <div key={row.key} className="cu-tooltip-row">
                <dt>
                  {row.swatch && <span className={`cu-swatch ${row.swatch}`} aria-hidden="true" />}
                  {row.label}
                </dt>
                <dd>{row.value}</dd>
              </div>
            ))}
          </dl>
        </div>
      )}
    </div>
  );
}

/** Horizontal grid lines with their labels on one side. */
function Grid({
  plot,
  max,
  side,
  format,
}: {
  plot: Plot;
  max: number;
  side: "left" | "right";
  format: (v: number) => string;
}) {
  return (
    <g className="cu-grid">
      {[0, 0.5, 1].map((share) => {
        const y = scaleY(max * share, max, plot);
        return (
          <g key={share}>
            {side === "left" && <line x1={plot.left} x2={plot.width - plot.right} y1={y} y2={y} />}
            <text
              x={side === "left" ? plot.left - 6 : plot.width - plot.right + 6}
              y={y}
              dy="0.32em"
              textAnchor={side === "left" ? "end" : "start"}
            >
              {format(max * share)}
            </text>
          </g>
        );
      })}
    </g>
  );
}

function XAxis({
  series,
  bucket,
  plot,
  language,
}: {
  series: UsagePoint[];
  bucket: UsageBucket;
  plot: Plot;
  language: string;
}) {
  const room = Math.max(2, Math.floor((plot.width - plot.left - plot.right) / 64));
  return (
    <g className="cu-axis">
      {axisLabelIndexes(series.length, room).map((index) => (
        <text key={index} x={slotCenter(index, series.length, plot)} y={plot.height - 4} textAnchor="middle">
          {bucketLabel(series[index]!.t, bucket, language)}
        </text>
      ))}
    </g>
  );
}

/** The legend: a swatch and a name per series, in stack order. */
export function Legend({ items }: { items: { key: string; label: string; swatch: string }[] }) {
  return (
    <ul className="cu-legend">
      {items.map((item) => (
        <li key={item.key}>
          <span className={`cu-swatch ${item.swatch}`} aria-hidden="true" />
          {item.label}
        </li>
      ))}
    </ul>
  );
}

export function tokenLegend(strings: Strings, withCost: boolean) {
  const items = TOKEN_KINDS.map((kind) => ({
    key: kind,
    label: strings.t(KIND_KEYS[kind]),
    swatch: `cu-kind-${kind}`,
  }));
  return withCost ? [...items, { key: "usd", label: strings.t("chiefUsage.series.cost"), swatch: "cu-cost" }] : items;
}

/**
 * Tokens per bucket stacked by kind (input, cache read, cache write, output), with the bucket's
 * cost as a line on its own scale at the right (`withCost`).
 */
export function TokenChart({
  series,
  bucket,
  strings,
  height = 200,
  withCost = true,
}: {
  series: UsagePoint[];
  bucket: UsageBucket;
  strings: Strings;
  height?: number;
  withCost?: boolean;
}) {
  const language = strings.language;
  const tokenMax = niceMax(
    Math.max(0, ...series.map((point) => point.input + point.output + point.cache_read + point.cache_write)),
  );
  const costMax = niceMax(Math.max(0, ...series.map((point) => point.usd)));
  return (
    <ChartBox
      label={strings.t(withCost ? "chiefUsage.chart.tokens" : "chiefUsage.chart.tokensOnly")}
      height={height}
      count={series.length}
      plot={(width) => ({ width, height, left: 44, right: withCost ? 52 : 8, top: 8, bottom: 20 })}
      tooltip={(index) => {
        const point = series[index]!;
        const rows: TooltipRow[] = [...TOKEN_KINDS].reverse().map((kind) => ({
          key: kind,
          label: strings.t(KIND_KEYS[kind]),
          value: formatTokens(point[kind], language),
          swatch: `cu-kind-${kind}`,
        }));
        if (withCost)
          rows.push({
            key: "usd",
            label: strings.t("chiefUsage.series.cost"),
            value: formatUSD(point.usd, language),
            swatch: "cu-cost",
          });
        return { title: bucketTitle(point.t, bucket, language), rows };
      }}
    >
      {(plot) => (
        <>
          <Grid plot={plot} max={tokenMax} side="left" format={(value) => formatTokens(value, language)} />
          {withCost && <Grid plot={plot} max={costMax} side="right" format={(value) => formatUSD(value, language)} />}
          {stackedBars(series, plot, tokenMax).map((bar) => (
            <g key={bar.index} className="cu-bar" data-index={bar.index}>
              {bar.segments.map((segment) => (
                <rect
                  key={segment.kind}
                  className={`cu-segment cu-kind-${segment.kind}`}
                  x={bar.x}
                  y={segment.y}
                  width={bar.width}
                  height={segment.height}
                  rx={Math.min(2, bar.width / 4)}
                />
              ))}
            </g>
          ))}
          {withCost && (
            <path
              className="cu-line cu-cost"
              d={linePath(
                series.map((point) => point.usd),
                costMax,
                plot,
              )}
            />
          )}
          <XAxis series={series} bucket={bucket} plot={plot} language={language} />
        </>
      )}
    </ChartBox>
  );
}

/** One measure per bucket as a line (`hit` as a share, `usd` as dollars). */
export function LineChart({
  series,
  bucket,
  strings,
  measure,
  height = 120,
}: {
  series: UsagePoint[];
  bucket: UsageBucket;
  strings: Strings;
  measure: "hit" | "usd";
  height?: number;
}) {
  const language = strings.language;
  const values = series.map((point) => (measure === "hit" ? point.hit : point.usd));
  const max = measure === "hit" ? 1 : niceMax(Math.max(0, ...series.map((point) => point.usd)));
  const format = (value: number | null) =>
    measure === "hit" ? formatPercent(value, language) : formatUSD(value ?? 0, language);
  const name = strings.t(measure === "hit" ? "chiefUsage.series.hit" : "chiefUsage.series.cost");
  const swatch = measure === "hit" ? "cu-hit-line" : "cu-cost";
  return (
    <ChartBox
      label={strings.t(measure === "hit" ? "chiefUsage.chart.hit" : "chiefUsage.chart.cost")}
      height={height}
      count={series.length}
      className={`cu-line-chart cu-measure-${measure}`}
      plot={(width) => ({ width, height, left: 44, right: 8, top: 8, bottom: 20 })}
      tooltip={(index) => ({
        title: bucketTitle(series[index]!.t, bucket, language),
        rows: [{ key: measure, label: name, value: format(values[index] ?? null), swatch }],
      })}
    >
      {(plot) => (
        <>
          <Grid plot={plot} max={max} side="left" format={(value) => format(value)} />
          <path className={`cu-line ${swatch}`} d={linePath(values, max, plot)} />
          {values.map((value, index) =>
            value === null ? null : (
              <circle
                key={index}
                className={`cu-dot ${swatch}`}
                cx={slotCenter(index, values.length, plot)}
                cy={scaleY(value, max, plot)}
                r={values.length > 40 ? 0 : 2.5}
              />
            ),
          )}
          <XAxis series={series} bucket={bucket} plot={plot} language={language} />
        </>
      )}
    </ChartBox>
  );
}

/** Turn time per bucket: the p50 as a line inside a p50 to p95 band. */
export function BandChart({
  series,
  bucket,
  strings,
  height = 120,
}: {
  series: UsagePoint[];
  bucket: UsageBucket;
  strings: Strings;
  height?: number;
}) {
  const language = strings.language;
  const p50 = series.map((point) => point.ms_p50);
  const p95 = series.map((point) => point.ms_p95);
  const max = niceMax(Math.max(0, ...p95.map((value) => value ?? 0)));
  return (
    <ChartBox
      label={strings.t("chiefUsage.chart.latency")}
      height={height}
      count={series.length}
      className="cu-band-chart"
      plot={(width) => ({ width, height, left: 44, right: 8, top: 8, bottom: 20 })}
      tooltip={(index) => ({
        title: bucketTitle(series[index]!.t, bucket, language),
        rows: [
          {
            key: "p95",
            label: strings.t("chiefUsage.series.p95"),
            value: formatMs(p95[index], language),
            swatch: "cu-band",
          },
          {
            key: "p50",
            label: strings.t("chiefUsage.series.p50"),
            value: formatMs(p50[index], language),
            swatch: "cu-p50",
          },
        ],
      })}
    >
      {(plot) => (
        <>
          <Grid plot={plot} max={max} side="left" format={(value) => formatMs(value, language)} />
          <path className="cu-band" d={bandPath(p50, p95, max, plot)} />
          <path className="cu-line cu-p50" d={linePath(p50, max, plot)} />
          <XAxis series={series} bucket={bucket} plot={plot} language={language} />
        </>
      )}
    </ChartBox>
  );
}

/** A small axis-less line for a sparkline card; hover names the bucket and its value. */
export function Sparkline({
  values,
  series,
  bucket,
  strings,
  label,
  format,
  swatch,
  height = 56,
}: {
  values: (number | null)[];
  series: UsagePoint[];
  bucket: UsageBucket;
  strings: Strings;
  label: string;
  format: (value: number | null) => string;
  swatch: string;
  height?: number;
}) {
  const max = niceMax(Math.max(0, ...values.map((value) => value ?? 0)));
  return (
    <ChartBox
      label={label}
      height={height}
      count={values.length}
      className="cu-sparkline"
      plot={(width) => ({ width, height, left: 2, right: 2, top: 4, bottom: 4 })}
      tooltip={(index) => ({
        title: bucketTitle(series[index]!.t, bucket, strings.language),
        rows: [{ key: "value", label, value: format(values[index] ?? null), swatch }],
      })}
    >
      {(plot) => <path className={`cu-line ${swatch}`} d={linePath(values, max, plot)} />}
    </ChartBox>
  );
}
