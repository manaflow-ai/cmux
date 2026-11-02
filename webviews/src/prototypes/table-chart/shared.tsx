// l10n-allow-file: gallery fixture data and controls, not shipped UI.
import { useEffect, useId, useMemo, useState, type MouseEvent, type ReactNode } from "react";

export type NumericSeries = "sessions" | "errors" | "rate";
export type Row = {
  day: string;
  sessions: number | null;
  errors: number | null;
  rate: number | null;
};
export type Props = { fixture?: "week" | "empty" | "single" | "mixed" | "large" };

const BASE: Row[] = [
  { day: "Mon", sessions: 184, errors: 8, rate: 4.3 },
  { day: "Tue", sessions: 236, errors: 7, rate: 3.0 },
  { day: "Wed", sessions: 292, errors: 11, rate: 3.8 },
  { day: "Thu", sessions: 318, errors: 6, rate: 1.9 },
  { day: "Fri", sessions: 364, errors: 9, rate: 2.5 },
  { day: "Sat", sessions: 241, errors: 5, rate: 2.1 },
  { day: "Sun", sessions: 207, errors: 4, rate: 1.9 },
];

export function rowsFor(fixture: Props["fixture"]): Row[] {
  if (fixture === "empty") return [];
  if (fixture === "single") return BASE.slice(0, 1);
  if (fixture === "mixed")
    return [
      { day: "Mon", sessions: -4, errors: 8, rate: 4.3 },
      { day: "Tue", sessions: null, errors: 7, rate: 3.0 },
      BASE[2]!,
    ];
  if (fixture === "large")
    return Array.from({ length: 1000 }, (_, i) => ({
      day: "D" + (i + 1),
      sessions: 120 + ((i * 37) % 260),
      errors: 3 + (i % 12),
      rate: Number((1.5 + ((i * 13) % 37) / 10).toFixed(1)),
    }));
  return BASE;
}

export function useTableData(fixture: Props["fixture"] = "week") {
  const [currentFixture, setFixture] = useState(fixture);
  const [series, setSeries] = useState<NumericSeries>("sessions");
  const [kind, setKind] = useState<"bar" | "line">("bar");
  const rows = useMemo(() => rowsFor(currentFixture), [currentFixture]);
  return { rows, currentFixture, setFixture, series, setSeries, kind, setKind };
}

export function Table({ rows, caption = "Source data" }: { rows: Row[]; caption?: string }) {
  return (
    <div className="tc-table-wrap">
      <table className="tc-table">
        <caption>{caption}</caption>
        <thead>
          <tr>
            <th scope="col">Day</th>
            <th scope="col">Sessions</th>
            <th scope="col">Errors</th>
            <th scope="col">Error rate</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={row.day + "-" + index}>
              <th scope="row">{row.day}</th>
              <td>{row.sessions ?? "—"}</td>
              <td>{row.errors ?? "—"}</td>
              <td>{row.rate === null ? "—" : row.rate + "%"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {!rows.length && <p className="tc-empty">No rows yet. Choose a fixture with data to visualize it.</p>}
    </div>
  );
}

export function Chart({
  rows,
  series,
  kind,
  title = "Visualization preview",
}: {
  rows: Row[];
  series: NumericSeries;
  kind: "bar" | "line";
  title?: string;
}) {
  const id = useId();
  const [plot, setPlot] = useState<SVGSVGElement | null>(null);
  const [plotWidth, setPlotWidth] = useState(560);
  useEffect(() => {
    if (!plot) return;
    const measure = () => setPlotWidth(Math.max(200, plot.getBoundingClientRect().width));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(plot);
    return () => observer.disconnect();
  }, [plot]);
  const values = rows.map((row) =>
    typeof row[series] === "number" && Number.isFinite(row[series]) ? row[series] : null,
  );
  const finite = values.filter((value): value is number => value !== null);
  if (!finite.length) return <output className="tc-chart-empty">Add numeric rows to preview a chart.</output>;
  const width = plotWidth,
    height = 260,
    pad = { left: 42, right: 18, top: 26, bottom: 42 };
  const max = Math.max(...finite, 0),
    min = Math.min(...finite, 0),
    span = max - min || 1;
  const x = (i: number) => pad.left + ((i + 0.5) / Math.max(values.length, 1)) * (width - pad.left - pad.right);
  const y = (v: number) => pad.top + (1 - (v - min) / span) * (height - pad.top - pad.bottom);
  // Leave room for the fixture labels at their unscaled 11px size, including D1000.
  const tickCount = Math.max(1, Math.min(7, Math.floor((width - pad.left - pad.right) / 40)));
  const tickStride = Math.max(1, Math.ceil(rows.length / tickCount));
  const segments: string[][] = [];
  values.forEach((value, i) => {
    if (value === null) segments.push([]);
    else {
      const current = segments[segments.length - 1] ?? [];
      if (!segments.length) segments.push(current);
      current.push(x(i) + "," + y(value));
    }
  });
  const label = series === "sessions" ? "Sessions" : series === "errors" ? "Errors" : "Error rate";
  return (
    <svg
      className="tc-chart"
      viewBox={"0 0 " + width + " " + height}
      ref={setPlot}
      aria-labelledby={`${id}-title ${id}-desc`}
    >
      <title id={`${id}-title`}>
        {title}: {label} by day
      </title>
      <desc id={`${id}-desc`}>
        {finite.length} plotted values; missing values remain gaps. Use the source table for exact values.
      </desc>
      <line x1={pad.left} x2={width - pad.right} y1={y(0)} y2={y(0)} className="tc-axis" />
      {kind === "bar"
        ? values.map((value, i) => {
            if (value === null) return null;
            const barW = Math.max(0.2, Math.min(48, ((width - pad.left - pad.right) / values.length) * 0.75));
            const baseline = y(0);
            const top = Math.min(y(value), baseline);
            return (
              <rect
                key={i}
                x={x(i) - barW / 2}
                y={top}
                width={barW}
                height={Math.abs(y(value) - baseline)}
                rx="3"
                className="tc-mark"
              />
            );
          })
        : segments
            .filter((segment) => segment.length > 1)
            .map((segment, i) => <polyline key={i} points={segment.join(" ")} className="tc-line" fill="none" />)}
      {kind === "line" &&
        values.map((value, i) =>
          value === null ? null : <circle key={i} cx={x(i)} cy={y(value)} r="4" className="tc-mark" />,
        )}
      {[min, min + span / 2, max].map((tick, i) => (
        <text key={i} x={pad.left - 8} y={y(tick) + 4} className="tc-label" textAnchor="end">
          {Number(tick.toFixed(1))}
          {series === "rate" ? "%" : ""}
        </text>
      ))}
      {rows
        .filter((_, i) => i % tickStride === 0)
        .map((row, i) => (
          <text key={row.day + "-" + i} x={x(i * tickStride)} y={height - 16} className="tc-label" textAnchor="middle">
            {row.day}
          </text>
        ))}
    </svg>
  );
}

export function Controls({ api, compact = false }: { api: ReturnType<typeof useTableData>; compact?: boolean }) {
  return (
    <div className={"tc-controls" + (compact ? " tc-controls--compact" : "")} aria-label="Visualization controls">
      <label>
        Rows{" "}
        <select
          value={api.currentFixture}
          onChange={(e) => api.setFixture(e.target.value as NonNullable<Props["fixture"]>)}
        >
          <option value="week">Week</option>
          <option value="single">One row</option>
          <option value="mixed">Mixed values</option>
          <option value="large">1,000 rows</option>
          <option value="empty">Empty</option>
        </select>
      </label>
      <label>
        Series{" "}
        <select value={api.series} onChange={(e) => api.setSeries(e.target.value as NumericSeries)}>
          <option value="sessions">Sessions</option>
          <option value="errors">Errors</option>
          <option value="rate">Error rate</option>
        </select>
      </label>
      <span className="tc-segment" aria-label="Chart type">
        <button type="button" aria-pressed={api.kind === "bar"} onClick={() => api.setKind("bar")}>
          Bars
        </button>
        <button type="button" aria-pressed={api.kind === "line"} onClick={() => api.setKind("line")}>
          Line
        </button>
      </span>
    </div>
  );
}

export function ExportButtons({ rows, chartVisible = true }: { rows: Row[]; chartVisible?: boolean }) {
  const [status, setStatus] = useState("");
  const csv = [
    "day,sessions,errors,rate",
    ...rows.map((r) => [r.day, r.sessions ?? "", r.errors ?? "", r.rate ?? ""].join(",")),
  ].join("\n");
  const save = (text: string, name: string, type: string) => {
    const url = URL.createObjectURL(new Blob([text], { type }));
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    link.click();
    URL.revokeObjectURL(url);
    setStatus("Download requested: " + name);
  };
  const exportChart = (event: MouseEvent<HTMLButtonElement>) => {
    const svg = event.currentTarget.closest(".tc-shell")?.querySelector<SVGSVGElement>(".tc-chart");
    if (!svg) {
      setStatus("Show a chart before exporting it.");
      return;
    }
    const copy = svg.cloneNode(true) as SVGSVGElement;
    copy.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    const originals = [svg, ...svg.querySelectorAll<SVGElement>("*")];
    const copies = [copy, ...copy.querySelectorAll<SVGElement>("*")];
    originals.forEach((node, index) => {
      const style = getComputedStyle(node);
      for (const property of [
        "fill",
        "stroke",
        "stroke-width",
        "stroke-linecap",
        "stroke-linejoin",
        "font-size",
        "font-family",
        "opacity",
      ])
        copies[index]!.style.setProperty(property, style.getPropertyValue(property));
    });
    const background = document.createElementNS("http://www.w3.org/2000/svg", "rect");
    background.setAttribute("width", "100%");
    background.setAttribute("height", "100%");
    background.setAttribute(
      "fill",
      getComputedStyle(svg).getPropertyValue("--cmux-surface-background").trim() || "white",
    );
    copy.insertBefore(background, copy.firstChild);
    save(new XMLSerializer().serializeToString(copy), "chart.svg", "image/svg+xml");
  };
  return (
    <div className="tc-export">
      <button type="button" onClick={() => save(csv, "chart-data.csv", "text/csv")}>
        Export CSV
      </button>
      <button
        type="button"
        disabled={!chartVisible || !rows.length}
        title={!chartVisible ? "Show the chart to export SVG" : undefined}
        onClick={exportChart}
      >
        Export SVG
      </button>
      <output aria-live="polite">{status}</output>
    </div>
  );
}

export function Shell({
  title,
  description,
  children,
  controls,
  footer,
}: {
  title: string;
  description: string;
  children: ReactNode;
  controls: ReactNode;
  footer?: ReactNode;
}) {
  return (
    <main className="tc-shell">
      <header>
        <p className="tc-eyebrow">Data preview</p>
        <h1>{title}</h1>
        <p className="tc-description">{description}</p>
      </header>
      {controls}
      {children}
      {footer}
    </main>
  );
}
