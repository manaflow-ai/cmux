// Needs you is an App Store item, off by default (Leo 2026-10-22: "he doesnt like this tho i kinda like
// this tho it's not too useful for me rn... app store maybe?"). Not installed, the host writes
// data-needs-you="off" on <html> (AgentPaneTunables documentAttributes): the header draws no inbox and
// leaves no slot (the remaining tools keep their order on the row's own gap), nothing can open the hidden
// list, and a reply's needs-you link draws as its text. Installed, the inbox leads the tools as before.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "getComputedStyle",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  // pretendToBeVisual: the opened list (a Base UI popover) schedules its transition on animation frames.
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    getComputedStyle: window.getComputedStyle.bind(window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  delete (scope.document as Document).documentElement.dataset.needsYou;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function renderHeader(installed: boolean) {
  const { createRoot } = await import("react-dom/client");
  const { ChatHeaderTools } = await import("../src/agent-session/acpmux/header/ChatHeaderTools");
  const { NeedsYouButton, needsYouMode } = await import("../src/agent-session/acpmux/needsYou/NeedsYou");
  const document = scope.document as Document;
  if (!installed) document.documentElement.dataset.needsYou = "off";
  const noop = () => {};
  root = createRoot(host);
  // As App.tsx draws the header: the inbox, then the tools, in one row.
  act(() =>
    root!.render(
      <header className="acpmux-header">
        <div className="acpmux-handoff-header-tools">
          <NeedsYouButton
            items={[]}
            mode={needsYouMode()}
            actions={{ answer: async () => undefined, goTo: noop, ask: async () => undefined }}
          />
          <ChatHeaderTools onTerminal={noop} onBrowser={noop} summary={null} menu={() => []} />
        </div>
      </header>,
    ),
  );
  const row = host.querySelector(".acpmux-handoff-header-tools")!;
  return {
    labels: [...host.querySelectorAll(".acpmux-header button")].map((button) => button.getAttribute("aria-label")),
    rowChildren: [...row.children].map((child) => child.className),
  };
}

test("not installed: no inbox button, and the row holds only the tools, with no empty slot", async () => {
  const on = await renderHeader(true);
  await act(async () => root?.unmount());
  delete (scope.document as Document).documentElement.dataset.needsYou;
  const off = await renderHeader(false);
  expect(on.labels[0]).toBe("Needs you");
  expect(host.querySelector(".acpmux-needs-you-button")).toBeNull();
  // The same tools in the same order, less the inbox: nothing else is added, removed or reordered.
  expect(off.labels).toEqual(on.labels.slice(1));
  // No placeholder element where the inbox was: the row's first child is the tools themselves.
  expect(off.rowChildren).toEqual(on.rowChildren.filter((name) => !name.includes("acpmux-needs-you")));
  expect(off.rowChildren.some((name) => name.includes("needs-you"))).toBe(false);
});

test("not installed: nothing opens the hidden list; installed, a link opens it", async () => {
  const { openNeedsYou } = await import("../src/agent-session/acpmux/needsYou/links");
  await renderHeader(false);
  expect(openNeedsYou("acpmux:abc")).toBe(false);
  expect((scope.document as Document).querySelector(".acpmux-needs-you-panel")).toBeNull();
  await act(async () => root?.unmount());
  delete (scope.document as Document).documentElement.dataset.needsYou;
  await renderHeader(true);
  let opened = false;
  // Async act: the opened popover's positioner settles inside it, not after this file's teardown.
  await act(async () => {
    opened = openNeedsYou("acpmux:abc");
  });
  expect(opened).toBe(true);
  expect(host.querySelector(".acpmux-needs-you-button")?.getAttribute("aria-expanded")).toBe("true");
});

test("a reply's needs-you link is a chip while installed and its plain text while not", async () => {
  const { renderToStaticMarkup } = await import("react-dom/server");
  const { renderInline } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const draw = () => renderToStaticMarkup(<>{renderInline("see [the deploy ask](cmux://needs-you/abc)")}</>);
  expect(draw()).toContain("is-needs-you");
  (scope.document as Document).documentElement.dataset.needsYou = "off";
  const off = draw();
  expect(off).not.toContain("is-needs-you");
  expect(off).not.toContain("<button");
  expect(off).toContain("the deploy ask");
});
