// A ```chart fence: a small JSON chart an agent can write without learning Vega-Lite, compiled here
// to a Vega-Lite spec and drawn by the same no-eval Vega path as a ```vega-lite fence (DiagramBlock.tsx).
// hq docs/design/next-rich-output.md, Leo 2026-11-14: "with graphs, charts, bars, whatever, like just
// tools that the LLM can maybe get if they want optionally".
//
//   {"type": "bar", "title": "Sales", "data": [{"month": "Jan", "sales": 3, "cost": 2}], "x": "month", "y": ["sales", "cost"]}
//   {"type": "line", "labels": ["Mon", "Tue"], "series": [{"name": "p50", "values": [12, 14]}]}
//
// type: bar, line, area, pie, scatter (default bar). x: the category or x field (default the first
// field). y: one field or a list (default every other numeric field); a list draws one series per
// field. series: a field that splits the rows into series. stacked: stack bars or areas. Labels and
// series (the common labels-and-series shape) become rows. Anything else is not a chart and stays code.

type Row = Record<string, unknown>;
export type ChartType = "bar" | "line" | "area" | "pie" | "scatter";
const TYPES: ReadonlySet<string> = new Set(["bar", "line", "area", "pie", "scatter"]);
const MAX_ROWS = 5000;
const ISO_DATE = /^\d{4}-\d{2}(?:-\d{2})?(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;

const isRow = (value: unknown): value is Row => typeof value === "object" && value !== null && !Array.isArray(value);
const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const numeric = (rows: readonly Row[], field: string) =>
  rows.some((row) => typeof row[field] === "number") &&
  rows.every((row) => row[field] == null || typeof row[field] === "number");

/// The rows a chart's `data`, or its `labels` and `series` (or `datasets`), name; undefined when neither does.
function chartRows(chart: Row): Row[] | undefined {
  if (Array.isArray(chart.data)) return chart.data.every(isRow) ? (chart.data as Row[]) : undefined;
  const series = Array.isArray(chart.series)
    ? chart.series
    : Array.isArray(chart.datasets)
      ? chart.datasets
      : undefined;
  if (!Array.isArray(chart.labels) || !series?.every(isRow)) return undefined;
  const labels = chart.labels as unknown[];
  return labels.map((label, index) => {
    const row: Row = { label };
    series.forEach((entry, at) => {
      const values = Array.isArray(entry.values) ? entry.values : Array.isArray(entry.data) ? entry.data : [];
      row[text(entry.name) ?? text(entry.label) ?? `series ${at + 1}`] = values[index];
    });
    return row;
  });
}

/// The Vega-Lite spec (JSON text) a ```chart fence's source draws as, or undefined when it is no chart.
export function chartSpec(source: string): string | undefined {
  let chart: unknown;
  try {
    chart = JSON.parse(source);
  } catch {
    return undefined;
  }
  if (!isRow(chart)) return undefined;
  const type = (text(chart.type)?.toLowerCase() ?? "bar") as ChartType;
  if (!TYPES.has(type)) return undefined;
  const rows = chartRows(chart);
  if (!rows?.length || rows.length > MAX_ROWS) return undefined;
  const fields = [...new Set(rows.flatMap((row) => Object.keys(row)))];
  const series = text(chart.series);
  const x = text(chart.x) ?? fields.find((field) => field !== series);
  if (!x) return undefined;
  const ys = (Array.isArray(chart.y) ? chart.y.map(text) : [text(chart.y)]).filter((y): y is string => !!y);
  const y = ys.length ? ys : fields.filter((field) => field !== x && field !== series && numeric(rows, field));
  if (!y.length || !y.every((field) => numeric(rows, field))) return undefined;

  // Several y fields fold into one value per row and field, a series each.
  const folded = y.length > 1;
  const value = folded ? "value" : y[0]!;
  const color = folded ? "series" : series;
  const xValues = rows.map((row) => row[x]);
  const xType = xValues.every((v) => typeof v === "number")
    ? "quantitative"
    : xValues.every((v) => typeof v === "string" && ISO_DATE.test(v))
      ? "temporal"
      : type === "line" || type === "area"
        ? "ordinal"
        : "nominal";
  const title = text(chart.title);
  const stacked = chart.stacked === true;
  const field = (name: string, kind: string, extra: Row = {}) => ({ field: name, type: kind, ...extra });
  const encoding: Row =
    type === "pie"
      ? { theta: field(value, "quantitative", { stack: true }), color: field(x, "nominal", { sort: null }) }
      : {
          x: field(x, type === "scatter" ? (xType === "nominal" ? "nominal" : xType) : xType, {
            ...(xType === "nominal" || xType === "ordinal" ? { sort: null } : {}),
            ...(text(chart.xTitle) ? { title: text(chart.xTitle) } : {}),
          }),
          y: field(value, "quantitative", {
            ...(text(chart.yTitle) ? { title: text(chart.yTitle) } : folded ? { title: null } : {}),
            ...((type === "bar" || type === "area") && color && !stacked ? { stack: null } : {}),
          }),
          ...(color ? { color: field(color, "nominal", { sort: null, title: null }) } : {}),
          ...(type === "bar" && color && !stacked ? { xOffset: field(color, "nominal", { sort: null }) } : {}),
        };
  const mark =
    type === "pie"
      ? { type: "arc", innerRadius: 0 }
      : type === "scatter"
        ? { type: "point", filled: true }
        : type === "line"
          ? { type: "line", point: rows.length <= 40 }
          : type === "area"
            ? { type: "area", opacity: color && !stacked ? 0.5 : 0.85, line: true }
            : { type: "bar", cornerRadiusEnd: 2 };
  const spec: Row = {
    ...(title ? { title } : {}),
    // Fixed sizes: Vega draws into a detached element, so "container" would measure nothing; the chat's
    // `.cv-diagram__chart svg { max-width: 100% }` scales a wide chart down in a narrow pane.
    width: type === "pie" ? 220 : 480,
    height: type === "pie" ? 220 : 240,
    data: { values: rows },
    ...(folded ? { transform: [{ fold: y, as: ["series", "value"] }] } : {}),
    mark,
    encoding,
  };
  return JSON.stringify(spec);
}
