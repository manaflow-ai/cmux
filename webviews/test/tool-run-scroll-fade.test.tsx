// l10n-allow-file: test fixture tool titles, not shipped UI.
// An opened run of tool calls ("Read files, ran commands") grows with the transcript instead of
// becoming a second vertical scroller. Collapsed rows never capture the wheel in the run itself.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { foldMotion } from "../src/agent-session/acpmux/conversation/fold";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { ToolRun } from "../src/agent-session/acpmux/conversation/ToolRun";
import { resetTranscriptDisclosure } from "../src/agent-session/acpmux/conversation/transcriptDisclosure";

let dom: JSDOM;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const motion = { ...foldMotion };
const GLOBALS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "localStorage",
  "MutationObserver",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of GLOBALS) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    localStorage: dom.window.localStorage,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  (dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = () => ({
    onfinish: null,
    cancel() {},
  });
  foldMotion.duration = () => 0;
  foldMotion.reducedMotion = () => true;
  resetTranscriptDisclosure();
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  Object.assign(foldMotion, motion);
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom.window.close();
});

const tool = (id: string): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: "" },
});

/// An opened run of twelve calls: the rows take their natural height in the transcript.
function openRun(): HTMLElement {
  const items = Array.from({ length: 12 }, (_, index) => tool(`file${index}`));
  act(() => {
    root ??= createRoot(dom.window.document.getElementById("root")!);
    root.render(
      <ToolRun disclosureKey="run:scroll" items={items}>
        {items.map((item) => (
          <ToolRow key={item.tool!.id} item={item} />
        ))}
      </ToolRun>,
    );
  });
  act(() => dom.window.document.querySelector<HTMLButtonElement>("button[aria-expanded]")!.click());
  const list = dom.window.document.querySelector<HTMLElement>(".cv-tool-run");
  expect(list).not.toBeNull();
  Object.defineProperty(list!, "scrollHeight", { configurable: true, value: 12 * 26 });
  Object.defineProperty(list!, "clientHeight", { configurable: true, value: 12 * 26 });
  return list!;
}

test("an opened run grows naturally and never owns a vertical scroll offset", () => {
  const list = openRun();
  expect(list.scrollHeight).toBe(list.clientHeight);
  expect(list.scrollTop).toBe(0);
  expect(list.hasAttribute("data-fade-top")).toBe(false);
});

test("the run keeps vertical overflow visible for the transcript scroller", async () => {
  const css = await Bun.file(
    new URL("../src/agent-session/acpmux/conversation/conversation.css", import.meta.url),
  ).text();
  const rule = /\.cv-tool-run\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(rule).toContain("max-height: none;");
  expect(rule).toContain("overflow: visible;");
  expect(rule).not.toContain("overflow-y: auto");
  expect(css).not.toMatch(/\.cv-tool-run\[data-fade-top\]/);
});
