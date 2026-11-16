// A transcript row's footer draws each button's icon as one element (Icon.tsx IconMaskContext): a span
// masked by the very svg the icon would draw, so a row an older page of a long chat mounts has no svg
// or path children in its footer to style. About a third of a mounted row's elements were icon svg and
// path nodes (transcript-scroll-up.bench.ts TRACE=3). Each mask is the drawing the inline svg holds.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div><div id=plain></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { UserBubble } = await import("../src/agent-session/acpmux/conversation/UserBubble");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { Icon } = await import("../src/agent-session/acpmux/icons/Icon");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);
const plainHost = dom.window.document.getElementById("plain")!;
const plain = createRoot(plainHost);

afterAll(async () => {
  act(() => root.unmount());
  act(() => plain.unmount());
  await teardownDom(saved, { window: dom.window, scope });
});

const prompt: AcpmuxRow = { id: "user-4", version: 1, at: Date.now(), kind: "user", seq: 4, text: "Cover it" };

test("a prompt's footer draws its icons with no svg or path elements", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          edit: { seqs: new Map([["user-4", 3]]), send: async () => true },
          branches: { of: new Map([["user-4", { sessions: ["a", "b", "c"], index: 1 }]]), open: () => {} },
        }}
      >
        <UserBubble row={prompt} text="Cover it" />
      </TurnActionsContext.Provider>,
    ),
  );
  const footer = host.querySelector(".cv-message-footer-row")!;
  const icons = footer.querySelectorAll("[data-icon]").length;
  const nodes = footer.querySelectorAll("svg, svg *").length;
  const elements = footer.querySelectorAll("*").length + 1;
  console.log(`prompt footer: ${elements} elements, ${icons} icons, ${nodes} svg and path nodes`);
  expect(icons).toBeGreaterThan(2);
  expect(nodes).toBe(0);
});

test("each footer icon's mask is the drawing its inline svg holds", async () => {
  const masks = [...host.querySelectorAll<HTMLElement>(".cv-message-footer-row .cmux-icon-mask")];
  expect(masks.length).toBeGreaterThan(2);
  for (const mask of masks) {
    const name = mask.getAttribute("data-icon")!;
    const size = Number.parseFloat(mask.style.getPropertyValue("--cmux-icon-size"));
    await act(async () => plain.render(<Icon name={name} size={size} />));
    const svg = plainHost.querySelector("svg")!;
    const url = mask.style.getPropertyValue("--cmux-icon-mask");
    const markup = decodeURIComponent(/^url\("data:image\/svg\+xml,(.*)"\)$/.exec(url)![1]!);
    const drawn = new dom.window.DOMParser().parseFromString(markup, "image/svg+xml").documentElement;
    expect(drawn.getAttribute("viewBox")).toBe(svg.getAttribute("viewBox"));
    // The same children: currentColor is black in a mask, and a knockout's mask id is the mask's own.
    const inline = svg.innerHTML.replaceAll("currentColor", "black").replace(/cmux-icon-[\w-]+?-m(\d+)/g, "m-m$1");
    const serialized = new dom.window.XMLSerializer()
      .serializeToString(drawn)
      .replace(/^<svg[^>]*>|<\/svg>$/g, "")
      .replaceAll(' xmlns="http://www.w3.org/2000/svg"', "");
    expect(serialized.replace(/\/>/g, ">").replace(/<(\w+)([^>]*)><\/\1>/g, "<$1$2>")).toBe(
      inline.replace(/\/>/g, ">").replace(/<(\w+)([^>]*)><\/\1>/g, "<$1$2>"),
    );
  }
});
