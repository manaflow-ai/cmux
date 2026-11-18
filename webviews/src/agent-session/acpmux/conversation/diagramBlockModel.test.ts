// A chart whose spec names its size draws into a box of that size, known before Vega loads, so the
// reply row never grows when the chart lands (schemas/layout-motion/contract.json).
import { describe, expect, test } from "bun:test";
import { chartSpec } from "./chartSpec";
import { FIT_AUTOSIZE, sizedChart } from "./diagramBlockModel";

const parse = (text: string) => JSON.parse(text) as Record<string, unknown>;

describe("sized chart", () => {
  test("a Vega-Lite view that names its size fits to it, padding included, and reserves it", () => {
    const source = JSON.stringify({ width: 420, height: 180, mark: "bar", data: { values: [] } });
    const { spec, box } = sizedChart("vega-lite", source);
    expect(box).toEqual({ width: 420, height: 180 });
    expect(parse(spec).autosize).toEqual(FIT_AUTOSIZE);
    expect(parse(spec).mark).toBe("bar");
  });

  test("a layered view fits too", () => {
    const source = JSON.stringify({ width: 300, height: 200, layer: [{ mark: "bar" }, { mark: "tick" }] });
    expect(sizedChart("vega-lite", source).box).toEqual({ width: 300, height: 200 });
  });

  test("a chart fence is a sized Vega-Lite view", () => {
    const fence = chartSpec(JSON.stringify({ type: "pie", data: [{ k: "a", v: 1 }], x: "k", y: "v" }))!;
    const { box } = sizedChart("vega-lite", fence);
    expect(box?.width).toBeGreaterThan(0);
    expect(box?.height).toBeGreaterThan(0);
  });

  test("a spec that sets its own autosize keeps it, and is reserved only when it fits to its padding", () => {
    const pad = JSON.stringify({ width: 300, height: 200, autosize: "pad", mark: "bar" });
    expect(sizedChart("vega-lite", pad)).toEqual({ spec: pad });
    const fit = JSON.stringify({ width: 300, height: 200, autosize: FIT_AUTOSIZE, mark: "bar" });
    expect(sizedChart("vega-lite", fit)).toEqual({ spec: fit, box: { width: 300, height: 200 } });
    expect(sizedChart("vega", fit).box).toEqual({ width: 300, height: 200 });
  });

  test("a view Vega-Lite cannot fit, a raw Vega spec, or a spec with no size draws as written", () => {
    for (const [mode, spec] of [
      ["vega-lite", { width: 300, height: 200, hconcat: [] }],
      ["vega-lite", { width: 300, height: 200, facet: {} }],
      ["vega-lite", { width: "container", height: 200, mark: "bar" }],
      ["vega-lite", { mark: "bar" }],
      ["vega", { width: 300, height: 200, marks: [] }],
    ] as const) {
      const source = JSON.stringify(spec);
      expect(sizedChart(mode, source)).toEqual({ spec: source });
    }
    expect(sizedChart("vega-lite", "{not json")).toEqual({ spec: "{not json" });
  });
});
