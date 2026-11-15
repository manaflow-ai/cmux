import { describe, expect, test } from "bun:test";
import { chartSpec } from "./chartSpec";
import { isChart } from "./diagramBlockModel";

const spec = (chart: unknown) => {
  const text = chartSpec(JSON.stringify(chart));
  return text === undefined ? undefined : (JSON.parse(text) as Record<string, any>);
};

describe("chart fence", () => {
  test("a bar chart of rows names its fields", () => {
    const out = spec({
      type: "bar",
      title: "Sales",
      data: [
        { month: "Jan", sales: 3 },
        { month: "Feb", sales: 5 },
      ],
    });
    expect(out?.mark.type).toBe("bar");
    expect(out?.title).toBe("Sales");
    expect(out?.encoding.x).toEqual({ field: "month", type: "nominal", sort: null });
    expect(out?.encoding.y.field).toBe("sales");
    expect(out?.data.values).toHaveLength(2);
  });

  test("several y fields fold into one series each, grouped side by side unless stacked", () => {
    const rows = [
      { q: "Q1", a: 1, b: 2 },
      { q: "Q2", a: 3, b: 4 },
    ];
    const grouped = spec({ type: "bar", data: rows });
    expect(grouped?.transform).toEqual([{ fold: ["a", "b"], as: ["series", "value"] }]);
    expect(grouped?.encoding.color.field).toBe("series");
    expect(grouped?.encoding.xOffset.field).toBe("series");
    const stacked = spec({ type: "bar", data: rows, stacked: true });
    expect(stacked?.encoding.xOffset).toBeUndefined();
    expect(stacked?.encoding.y.stack).toBeUndefined();
  });

  test("labels and series (the common labels-and-series shape) become rows", () => {
    const out = spec({ type: "line", labels: ["Mon", "Tue"], series: [{ name: "p50", values: [12, 14] }] });
    expect(out?.data.values).toEqual([
      { label: "Mon", p50: 12 },
      { label: "Tue", p50: 14 },
    ]);
    expect(out?.encoding.x.type).toBe("ordinal");
    expect(out?.mark).toEqual({ type: "line", point: true });
  });

  test("dates are temporal, numbers quantitative, a pie is an arc by category", () => {
    expect(
      spec({
        type: "line",
        data: [
          { d: "2026-11-01", v: 1 },
          { d: "2026-11-02", v: 2 },
        ],
      })?.encoding.x.type,
    ).toBe("temporal");
    expect(
      spec({
        type: "scatter",
        data: [
          { x: 1, y: 2 },
          { x: 2, y: 3 },
        ],
      })?.encoding.x.type,
    ).toBe("quantitative");
    const pie = spec({
      type: "pie",
      data: [
        { k: "a", v: 1 },
        { k: "b", v: 2 },
      ],
    });
    expect(pie?.mark.type).toBe("arc");
    expect(pie?.encoding.theta.field).toBe("v");
    expect(pie?.encoding.color.field).toBe("k");
  });

  test("a series field colors rows; x and y titles carry over", () => {
    const out = spec({
      type: "line",
      data: [{ t: 1, v: 2, host: "a" }],
      x: "t",
      y: "v",
      series: "host",
      xTitle: "Time",
      yTitle: "ms",
    });
    expect(out?.encoding.color.field).toBe("host");
    expect(out?.encoding.x.title).toBe("Time");
    expect(out?.encoding.y.title).toBe("ms");
  });

  test("anything else is not a chart", () => {
    for (const source of [
      "",
      "nope",
      "[]",
      "{}",
      '{"type":"radar","data":[{"a":1}]}',
      '{"data":[{"a":"x"}]}',
      '{"data":[]}',
      '{"data":[1,2]}',
      '{"data":[{"k":"a","v":"high"}],"y":"v"}',
    ])
      expect(chartSpec(source)).toBeUndefined();
  });

  test("the fence draws only a chart it can compile", () => {
    expect(isChart("chart", '{"data":[{"k":"a","v":1}]}')).toBe(true);
    expect(isChart("Chart", '{"data":[{"k":"a","v":1}]}')).toBe(true);
    expect(isChart("chart", '{"data":[]}')).toBe(false);
    expect(isChart("vega-lite", "{}")).toBe(true);
  });
});
