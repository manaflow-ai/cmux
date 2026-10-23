// l10n-allow-file: test fixture tool titles, not shipped UI.
// An opened run of tool calls ("Read files, ran commands") lists its calls in a box that scrolls past
// nine rows (.cv-tool-run). Scrolled, the box's top fades out under the summary line (Leo
// 2026-10-21: "in that top section fade would be good") instead of cutting a row in half against
// it. The edge is marked (`data-fade-top`, scrollEdges.ts) only while rows lie above it, and faded
// with an alpha mask on the box itself, as the transcript's top edge is: nothing is painted over the
// rows, so the fade covers no text and catches no clicks.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
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
  "ResizeObserver",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
];

/// JSDOM has no layout: the observers the edge marks follow, recorded so the test can fire them.
let resizes: (() => void)[] = [];
class FakeResizeObserver {
  constructor(private readonly callback: () => void) {
    resizes.push(() => this.callback());
  }
  observe() {}
  unobserve() {}
  disconnect() {}
}

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
    ResizeObserver: FakeResizeObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  (dom.window.HTMLElement.prototype as unknown as { animate: unknown }).animate = () => ({
    onfinish: null,
    cancel() {},
  });
  foldMotion.duration = () => 0;
  foldMotion.reducedMotion = () => true;
  resizes = [];
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

/// An opened run of twelve calls, three past the box's nine-row cap.
function openRun(): HTMLElement {
  const items = Array.from({ length: 12 }, (_, index) => tool(`file${index}`));
  act(() => {
    root ??= createRoot(dom.window.document.getElementById("root")!);
    root.render(
      <ToolRun disclosureKey="run:fade" items={items}>
        {items.map((item) => (
          <ToolRow key={item.tool!.id} item={item} />
        ))}
      </ToolRun>,
    );
  });
  act(() => dom.window.document.querySelector<HTMLButtonElement>("button[aria-expanded]")!.click());
  const list = dom.window.document.querySelector<HTMLElement>(".cv-tool-run");
  expect(list).not.toBeNull();
  // Twelve 26px rows in the 234px box.
  Object.defineProperty(list!, "scrollHeight", { configurable: true, value: 12 * 26 });
  Object.defineProperty(list!, "clientHeight", { configurable: true, value: 234 });
  return list!;
}

function scrollTo(list: HTMLElement, top: number) {
  list.scrollTop = top;
  list.dispatchEvent(new dom.window.Event("scroll"));
}

test("an opened run's list fades its top only while rows lie above it", () => {
  const list = openRun();
  for (const fire of resizes) fire();
  expect(list.hasAttribute("data-fade-top")).toBe(false);

  // A row half under the summary line: 3.5 rows scrolled away.
  scrollTo(list, 26 * 3.5);
  expect(list.hasAttribute("data-fade-top")).toBe(true);

  scrollTo(list, 0);
  expect(list.hasAttribute("data-fade-top")).toBe(false);
});

test("the fade is an alpha mask on the list, never a painted overlay that covers or catches clicks", () => {
  const css = readFileSync(
    path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
    "utf8",
  );
  const rule = /\.cv-tool-run\[data-fade-top\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  expect(rule).toContain("mask-image:");
  expect(rule).toContain("-webkit-mask-image:");
  // Transparent at the box's top edge, full ink a band below it.
  expect(rule).toMatch(/linear-gradient\(to bottom, transparent, #000 var\(--cv-tool-run-fade-top\)\)/);
  expect(rule).toMatch(/--cv-tool-run-fade-top:\s*18px/);
  // Nothing painted: no background, and no pseudo-element laid over the rows to catch the pointer.
  expect(rule).not.toMatch(/background/);
  expect(css).not.toMatch(/\.cv-tool-run[^{]*::?(before|after)/);
  // Reduce Transparency keeps a plain edge.
  expect(css).toMatch(/:root\[data-reduce-transparency\] \.cv-tool-run\[data-fade-top\]\s*\{[^}]*mask-image:\s*none/);
});
