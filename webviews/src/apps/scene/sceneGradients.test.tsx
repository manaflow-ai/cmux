import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { UiProvider } from "../../ui/UiProvider";
import { SceneRenderer } from "./SceneRenderer";
import { sceneGradient, sceneStyle } from "./sceneStyle";
import { scenePalette, sceneSymbolRendering, symbolGlyphColor } from "./sceneSymbolRendering";
import { SceneStore, type SceneOp } from "./store";
import { settleReact } from "../../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function render(ops: SceneOp[]) {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  const values: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    MutationObserver: dom.window.MutationObserver,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(values)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = document.getElementById("root")!;
  const clientPath = fileURLToPath(
    new URL("./cjs/react-dom-client.development.js", import.meta.resolve("react-dom/client")),
  );
  delete require.cache[clientPath];
  const { createRoot } = require(clientPath) as typeof import("react-dom/client");
  const store = new SceneStore();
  store.apply(ops);
  root = createRoot(container);
  act(() =>
    root!.render(
      <UiProvider container={container}>
        <SceneRenderer store={store} dispatch={() => undefined} />
      </UiProvider>,
    ),
  );
  return container;
}

const icon = (props: Record<string, unknown>): SceneOp[] => [
  { op: "create", id: "icon", type: "Icon", props },
  { op: "root", id: "icon" },
];

const paths = (container: HTMLElement) =>
  [...container.querySelectorAll('[data-app-node="icon"] path')].map((path) => ({
    fill: path.getAttribute("fill"),
    stroke: path.getAttribute("stroke"),
    opacity: path.getAttribute("opacity"),
  }));

test("a linear gradient becomes a CSS linear-gradient with tokens resolved and the angle normalized", () => {
  expect(sceneGradient({ linear: { colors: ["#112233", "success"] } })).toBe(
    "linear-gradient(180deg, #112233, var(--agent-status-success))",
  );
  expect(sceneGradient({ linear: { colors: ["#112233", "#445566AA"], angle: -90 } })).toBe(
    "linear-gradient(270deg, #112233, #445566AA)",
  );
  expect(sceneGradient({ radial: { colors: ["#FFCC00", "#FF9F0A", "#FF453A"] } })).toBe(
    "radial-gradient(closest-side, #FFCC00, #FF9F0A, #FF453A)",
  );
});

test("a gradient that is not exactly the documented shape is refused", () => {
  const refused: unknown[] = [
    { linear: { colors: ["#112233"] } },
    { linear: { colors: Array.from({ length: 9 }, () => "#112233") } },
    { linear: { colors: ["#112233", "red"] } },
    { linear: { colors: ["#112233", "url(x)"] } },
    { linear: { colors: ["#112233", "#445566"], angle: "90deg" } },
    { linear: { colors: ["#112233", "#445566"], stops: [0, 1] } },
    { radial: { colors: ["#112233", "#445566"], angle: 90 } },
    { linear: { colors: ["#112233", "#445566"] }, radial: { colors: ["#112233", "#445566"] } },
    { conic: { colors: ["#112233", "#445566"] } },
    "linear-gradient(red, blue)",
    ["#112233", "#445566"],
  ];
  for (const value of refused) expect(sceneGradient(value)).toBeUndefined();
});

test("background takes a gradient as an image and a color as a color, never both", () => {
  const gradient = sceneStyle({ background: { linear: { colors: ["#0B1A3A", "#3A4E86"] } } });
  expect(gradient.backgroundImage).toBe("linear-gradient(180deg, #0B1A3A, #3A4E86)");
  expect(gradient.backgroundColor).toBeUndefined();
  const color = sceneStyle({ background: "#0B1A3A" });
  expect(color.backgroundColor).toBe("#0B1A3A");
  expect(color.backgroundImage).toBeUndefined();
  const bad = sceneStyle({ background: { linear: { colors: ["red", "blue"] } } });
  expect(bad.backgroundImage).toBeUndefined();
  expect(bad.backgroundColor).toBeUndefined();
});

test("rendering modes and palettes are validated", () => {
  expect(sceneSymbolRendering("multicolor")).toBe("multicolor");
  expect(sceneSymbolRendering("rainbow")).toBeUndefined();
  expect(scenePalette(["#FFFFFF", "warning"])).toEqual(["#FFFFFF", "var(--agent-status-warning)"]);
  expect(scenePalette([])).toBeUndefined();
  expect(scenePalette(["#FFFFFF", "#FFFFFF", "#FFFFFF", "#FFFFFF"])).toBeUndefined();
  expect(scenePalette(["#FFFFFF", "blue"])).toBeUndefined();
});

test("multicolor colors a one-color glyph and keeps the tint for a layered entry or an unlisted symbol", () => {
  expect(symbolGlyphColor("sun.max.fill", "multicolor", undefined)).toBe("#FFCC00");
  expect(symbolGlyphColor("cloud.sun.rain.fill", "multicolor", undefined)).toBeUndefined();
  expect(symbolGlyphColor("folder", "multicolor", undefined)).toBeUndefined();
  expect(symbolGlyphColor("sun.max.fill", "monochrome", undefined)).toBeUndefined();
});

test("palette draws in its first color; hierarchical and a bad palette keep the tint", () => {
  expect(symbolGlyphColor("account", "palette", ["#FFFFFF", "#FFCC00"])).toBe("#FFFFFF");
  expect(symbolGlyphColor("account", "palette", ["blue"])).toBeUndefined();
  expect(symbolGlyphColor("account", "hierarchical", undefined)).toBeUndefined();
});

const glyphColor = (container: HTMLElement) =>
  container.querySelector<SVGElement>('[data-app-node="icon"] svg')?.style.color ?? "";

test("an Icon in palette mode draws in the palette's first color", () => {
  const container = render(
    icon({ symbol: "account", symbolRendering: "palette", symbolColors: ["#FFFFFF", "#FFCC00"] }),
  );
  expect(glyphColor(container)).toBe("rgb(255, 255, 255)");
});

test("multicolor on a mapped SF name colors the pack glyph", () => {
  const container = render(icon({ symbol: "exclamationmark.triangle.fill", symbolRendering: "multicolor" }));
  expect(glyphColor(container)).toBe("rgb(255, 204, 0)");
  expect(paths(container).length).toBeGreaterThan(0);
});

test("monochrome, hierarchical and an unknown mode draw every layer in the tint", () => {
  for (const symbolRendering of ["monochrome", "hierarchical", "rainbow", undefined]) {
    const container = render(icon({ symbol: "account", symbolRendering }));
    expect(glyphColor(container)).toBe("");
    expect(paths(container).every((path) => path.stroke === "currentColor")).toBe(true);
    act(() => root?.unmount());
    root = undefined;
  }
});

test("a shape's gradient fill replaces its fill color", () => {
  const container = render([
    {
      op: "create",
      id: "dot",
      type: "Circle",
      props: { size: 20, fill: { radial: { colors: ["#FFCC00", "#FF453A"] } } },
    },
    { op: "root", id: "dot" },
  ]);
  const dot = container.querySelector<HTMLElement>('[data-app-node="dot"]')!;
  expect(dot.style.backgroundColor).toBe("");
  expect(dot.style.backgroundImage).toContain("radial-gradient(");
});
