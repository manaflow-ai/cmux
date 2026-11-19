import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { fileURLToPath } from "node:url";
import { UiProvider } from "../../ui/UiProvider";
import { SceneRenderer } from "./SceneRenderer";
import { sceneTrim } from "./sceneStyle";
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
  return { container, store };
}

const shape = (type: string, props: Record<string, unknown>): SceneOp[] => [
  { op: "create", id: "s", type, props },
  { op: "root", id: "s" },
];

/** A scene rendered to markup with no DOM: the bytes an untrimmed scene draws. */
const markup = (ops: SceneOp[]) => {
  const store = new SceneStore();
  store.apply(ops);
  return renderToStaticMarkup(<SceneRenderer store={store} dispatch={() => undefined} />);
};

test("sceneTrim clamps to 0..1, keeps from at or before to, and refuses a value with no finite to", () => {
  expect(sceneTrim({ to: 0.7, lineCap: "round" })).toEqual({ from: 0, to: 0.7, lineCap: "round" });
  expect(sceneTrim({ from: -1, to: 2 })).toEqual({ from: 0, to: 1, lineCap: "butt" });
  expect(sceneTrim({ from: 0.6, to: 0.2, lineCap: "square" })).toEqual({ from: 0.6, to: 0.6, lineCap: "butt" });
  expect(sceneTrim(undefined)).toBeUndefined();
  expect(sceneTrim({})).toBeUndefined();
  expect(sceneTrim({ to: "0.5" })).toBeUndefined();
  expect(sceneTrim({ to: Number.NaN })).toBeUndefined();
});

test("a trimmed Circle draws an SVG arc from 12 o'clock, clockwise, and no border", () => {
  const { container } = render(
    shape("Circle", { size: 44, stroke: "#FF2D55", strokeWidth: 6, trim: { to: 0.7, lineCap: "round" } }),
  );
  const node = container.querySelector<HTMLElement>('[data-app-node="s"]')!;
  expect(node.style.borderStyle).toBe("");
  expect(node.style.backgroundColor).toBe("transparent");
  const svg = node.querySelector("svg.cmux-app-scene-shape-svg")!;
  expect(svg.getAttribute("viewBox")).toBe("0 0 44 44");
  const circle = svg.querySelector("circle")!;
  expect(circle.getAttribute("pathLength")).toBe("1");
  expect(circle.getAttribute("r")).toBe("19");
  expect(circle.getAttribute("stroke-width")).toBe("6");
  // SVG's circle starts at 3 o'clock; a quarter turn back puts the start at 12.
  expect(circle.getAttribute("transform")).toBe("rotate(-90 22 22)");
  expect(circle.style.strokeDasharray).toBe("0.7 1");
  expect(circle.style.strokeDashoffset).toBe("0");
  expect(circle.style.strokeLinecap).toBe("round");
  expect(circle.style.stroke).toBe("rgb(255, 45, 85)");
});

test("from offsets the arc; an empty arc has butt caps so it draws no dot; a trim change redraws the arc", () => {
  const { container, store } = render(shape("Circle", { size: 20, stroke: "accent", trim: { from: 0.25, to: 0.75 } }));
  const circle = () => container.querySelector<SVGCircleElement>('[data-app-node="s"] circle')!;
  expect(circle().style.strokeDasharray).toBe("0.5 1");
  expect(circle().style.strokeDashoffset).toBe("-0.25");
  expect(circle().style.strokeLinecap).toBe("butt");
  act(() => store.apply([{ op: "update", id: "s", props: { trim: { to: 0, lineCap: "round" } } }]));
  expect(circle().style.strokeDasharray).toBe("0 1");
  expect(circle().style.strokeLinecap).toBe("butt");
  act(() => store.apply([{ op: "update", id: "s", props: { trim: null } }]));
  expect(container.querySelector('[data-app-node="s"] svg')).toBeNull();
  expect(container.querySelector<HTMLElement>('[data-app-node="s"]')!.style.borderStyle).toBe("solid");
});

test("a trimmed RoundedRectangle draws a rect outline; trim without a stroke or a valid to changes nothing", () => {
  const { container } = render([
    { op: "create", id: "stack", type: "VStack", props: {} },
    {
      op: "create",
      id: "r",
      type: "RoundedRectangle",
      props: {
        frame: { width: 40, height: 20 },
        stroke: "success",
        strokeWidth: 2,
        cornerRadius: 6,
        trim: { to: 0.5 },
      },
    },
    { op: "create", id: "f", type: "Circle", props: { size: 20, fill: "accent", trim: { to: 0.5 } } },
    { op: "create", id: "b", type: "Circle", props: { size: 20, stroke: "accent", trim: { from: 0.5 } } },
    { op: "children", id: "stack", children: ["r", "f", "b"] },
    { op: "root", id: "stack" },
  ]);
  const rect = container.querySelector('[data-app-node="r"] rect')!;
  expect([
    rect.getAttribute("x"),
    rect.getAttribute("width"),
    rect.getAttribute("height"),
    rect.getAttribute("rx"),
  ]).toEqual(["1", "38", "18", "6"]);
  expect(container.querySelector('[data-app-node="f"] svg')).toBeNull();
  expect(container.querySelector('[data-app-node="b"] svg')).toBeNull();
  expect(container.querySelector<HTMLElement>('[data-app-node="b"]')!.style.borderStyle).toBe("solid");
});

test("untrimmed shapes render byte-identical to a scene with no trim support", () => {
  // The markup the renderer drew for these shapes before trim existed (checked against feat-cmux-next ae733ab0f78).
  const ops: SceneOp[] = [
    { op: "create", id: "stack", type: "HStack", props: {} },
    { op: "create", id: "a", type: "Circle", props: { size: 10, stroke: "accent", strokeWidth: 2 } },
    { op: "create", id: "b", type: "Capsule", props: { frame: { width: 30, height: 8 }, fill: "success" } },
    { op: "create", id: "c", type: "RoundedRectangle", props: { size: 12, stroke: "#112233", animation: "smooth" } },
    { op: "children", id: "stack", children: ["a", "b", "c"] },
    { op: "root", id: "stack" },
  ];
  expect(markup(ops)).toBe(
    '<div class="cmux-app-scene-root"><div data-app-node="stack" data-app-type="HStack" class="cmux-app-scene-node cmux-app-scene-hstack">' +
      '<div data-app-node="a" data-app-type="Circle" class="cmux-app-scene-node cmux-app-scene-circle" style="background-color:transparent;width:10px;height:10px;border-color:var(--cmux-accent, var(--agent-text));border-style:solid;border-width:2px"></div>' +
      '<div data-app-node="b" data-app-type="Capsule" class="cmux-app-scene-node cmux-app-scene-capsule" style="width:30px;height:8px;background-color:var(--agent-status-success)"></div>' +
      '<div data-app-node="c" data-app-type="RoundedRectangle" data-animation="smooth" class="cmux-app-scene-node cmux-app-scene-roundedrectangle" style="background-color:transparent;width:12px;height:12px;border-color:#112233;border-style:solid;border-width:1px"></div>' +
      "</div></div>",
  );
});
