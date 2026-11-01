// l10n-allow-file: test fixture chart source, not shipped UI.
// A drawn chart or diagram offers Save: its SVG goes to the host's save panel (`pane.saveFile`, kind svg),
// and is copied instead where the host has none. Nothing is offered before the chart is drawn.
import { afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import * as clipboard from "./clipboard";

type Call = { method: string; params: Record<string, unknown> };
const calls: Call[] = [];
let hostSaves = true;
let drawGate: Promise<void> = Promise.resolve();
await mock.module("../native", () => ({
  postNative: async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    if (!hostSaves) throw new Error("no host");
    return true;
  },
}));
await mock.module("../../../pages/markdown/diagrams", () => ({
  DiagramLibraries: class {},
  renderMermaid: async (_libs: unknown, _source: string, target: HTMLElement) => {
    await drawGate;
    target.innerHTML = '<svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>';
  },
  renderVega: async () => undefined,
  cancelDiagram: () => undefined,
}));
const copied: string[] = [];
await mock.module("./clipboard", () => ({ ...clipboard, copyText: async (text: string) => void copied.push(text) }));
const { DiagramBlock } = await import("./DiagramBlock");

let dom: JSDOM | undefined;
let root: Root | undefined;
let container: HTMLElement;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const GLOBALS = ["window", "document", "navigator", "HTMLElement", "Node", "XMLSerializer", "IS_REACT_ACT_ENVIRONMENT"];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "cmux-page://cmux.agent/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    XMLSerializer: dom.window.XMLSerializer,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  calls.length = 0;
  copied.length = 0;
  hostSaves = true;
  drawGate = Promise.resolve();
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  dom?.window.close();
});

const settle = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
const saveButton = () => container.querySelector<HTMLButtonElement>('button[aria-label="Save"]');

test("a drawn diagram saves its SVG through the host's save panel", async () => {
  await act(async () => root!.render(<DiagramBlock lang="mermaid" code="graph TD; A-->B" />));
  await settle();
  expect(saveButton()).not.toBeNull();
  await act(async () => saveButton()!.click());
  expect(calls).toHaveLength(1);
  expect(calls[0]!.method).toBe("pane.saveFile");
  expect(calls[0]!.params.kind).toBe("svg");
  expect(String(calls[0]!.params.text)).toContain('xmlns="http://www.w3.org/2000/svg"');
  expect(String(calls[0]!.params.text)).toContain("<rect");
  expect(copied).toEqual([]);
});

test("a host that cannot save gets the SVG on the clipboard instead", async () => {
  hostSaves = false;
  await act(async () => root!.render(<DiagramBlock lang="mermaid" code="graph TD; A-->B" />));
  await settle();
  await act(async () => saveButton()!.click());
  await settle();
  expect(copied).toHaveLength(1);
  expect(copied[0]).toContain("<svg");
});

test("nothing is offered before the chart is drawn", async () => {
  let release: () => void = () => undefined;
  drawGate = new Promise((resolve) => (release = resolve));
  await act(async () => root!.render(<DiagramBlock lang="mermaid" code="graph TD; A-->B" />));
  await settle();
  expect(saveButton()).toBeNull();
  release();
  await settle();
  expect(saveButton()).not.toBeNull();
});
