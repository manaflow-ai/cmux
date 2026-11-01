// A reply's closed ```html or ```svg fence draws inline as its document (InlinePreview.tsx, leo-workspace
// design/artifacts.md). The frame is sandboxed with exactly `allow-scripts` (never same-origin). In the
// app it is the native artifact frame, which gets the document made inert (no refresh, no resource
// hints, no outbound link); in the gallery it is srcdoc behind a policy with no network and no script
// but the client's nonce'd frame script. Its height follows only its own frame's report, capped; a
// fence still arriving renders nothing; a document with script stays the code card (Run is in the
// side panel). The browser half (scripts cannot reach the parent, fetch is refused) is
// inline-html-svg-preview-browser.test.ts.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: new URL("cmux-agent://pane/index.html"),
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Range: dom.window.Range,
  DOMParser: dom.window.DOMParser,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  // The pane's code card highlights in a worker on a cmux-agent: page (highlightPool.ts); jsdom has
  // none to start, so the card draws without one, as on the dev server.
  Worker: undefined,
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const PANE = new URL("cmux-agent://pane/index.html");
const GALLERY = new URL("http://127.0.0.1/gallery/frame.html?entry=agent-pane.inline-preview");
const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
const { INLINE_PREVIEW_MAX_HEIGHT, INLINE_PREVIEW_SIZE, inlinePreviewDocument, inlinePreviewHtml, inlinePreviewKind } =
  await import("../src/agent-session/acpmux/conversation/previewDocument");

async function show(source: string, streaming = false, page = PANE) {
  scope.location = page;
  root ??= createRoot(host);
  // A new page is a new tree, as a reload is.
  await act(async () =>
    root!.render(
      <Markdown key={page.href} streaming={streaming}>
        {source}
      </Markdown>,
    ),
  );
}
const frame = () => host.querySelector<HTMLIFrameElement>(".cv-inline-preview iframe");
const button = (name: string) =>
  [...host.querySelectorAll("button")].find(
    (element) => element.textContent === name || element.getAttribute("aria-label") === name,
  );
/// A message from `source` to the page, as a frame posts one.
const post = (source: unknown, data: unknown) =>
  act(() => {
    dom.window.dispatchEvent(new dom.window.MessageEvent("message", { data, source: source as Window }));
  });
const parse = (html: string) => new DOMParser().parseFromString(html, "text/html");

const SVG = '<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="red"/></svg>';

test("only html and svg fences preview inline", () => {
  expect(inlinePreviewKind("svg", SVG)).toBe("svg");
  expect(inlinePreviewKind("HTML", "<p>hi</p>")).toBe("html");
  expect(inlinePreviewKind("xml", SVG)).toBe("svg");
  expect(inlinePreviewKind("jsx", "<p>hi</p>")).toBeUndefined();
  expect(inlinePreviewKind("cmux-render", "<p>hi</p>")).toBeUndefined();
  expect(inlinePreviewKind("markdown", "# hi")).toBeUndefined();
  expect(inlinePreviewKind("html", "  ")).toBeUndefined();
});

test("in the app a closed svg fence draws in the native artifact frame, sandboxed with exactly allow-scripts", async () => {
  await show("Chart:\n\n```svg\n" + SVG + "\n```\n");
  const iframe = frame()!;
  expect(iframe.getAttribute("sandbox")).toBe("allow-scripts");
  expect(iframe.getAttribute("sandbox")).not.toContain("allow-same-origin");
  expect(iframe.getAttribute("src")).toBe("cmux-agent://render/artifact");
  // Not srcdoc: a srcdoc frame takes the pane's policy, which runs no inline script.
  expect(iframe.getAttribute("srcdoc")).toBeNull();
  // The frame asks for the document once it loads, and gets the inert one.
  const sent: { type?: string; html?: string }[] = [];
  iframe.contentWindow!.postMessage = ((data: { type?: string; html?: string }) => sent.push(data)) as never;
  await post(iframe.contentWindow, { type: "cmux-render-ready" });
  expect(sent).toHaveLength(1);
  expect(sent[0]!.type).toBe("cmux-render");
  expect(sent[0]!.html).toBe(inlinePreviewHtml("svg", SVG));
  expect(sent[0]!.html).toContain(SVG);
});

test("the frame follows only its own height report, capped, and Expand lifts the cap", async () => {
  await show("```html\n<p>tall</p>\n```\n");
  const iframe = frame()!;
  await post(iframe.contentWindow, { type: "cmux-render-size", height: 200 });
  expect(iframe.style.height).toBe("200px");
  // Another window's report is ignored.
  await post(dom.window, { type: "cmux-render-size", height: 300 });
  expect(iframe.style.height).toBe("200px");
  // Past the cap the card stops growing and the document scrolls; Expand lifts the cap.
  await post(iframe.contentWindow, { type: "cmux-render-size", height: 2_000 });
  expect(iframe.style.height).toBe(`${INLINE_PREVIEW_MAX_HEIGHT}px`);
  await act(() => button("Expand")!.click());
  expect(iframe.style.height).toBe("2000px");
});

test("a fence still arriving renders nothing, and previews once it closes", async () => {
  await show("Chart:\n\n```svg\n" + SVG + "\n", true);
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.textContent).toContain("<svg");
  await show("Chart:\n\n```svg\n" + SVG + "\n```\n", true);
  expect(frame()).not.toBeNull();
});

test("Code shows the source card with Copy, and Preview brings the frame back", async () => {
  await show("```svg\n" + SVG + "\n```\n");
  expect(button("Copy code")).toBeDefined();
  await act(() => button("Code")!.click());
  expect(frame()).toBeNull();
  expect(host.querySelector(".cv-codeblock")).not.toBeNull();
  expect(button("Copy code")).toBeDefined();
  await act(() => button("Preview")!.click());
  expect(frame()).not.toBeNull();
});

test("a document with script stays the code card, with no inline Run", async () => {
  await show('```html\n<button onclick="this.textContent=1">0</button>\n```\n');
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".cv-codeblock")).not.toBeNull();
  expect(button("Run")).toBeUndefined();
});

test("a page with no frame to draw in (the dev server) shows the source", async () => {
  await show("```svg\n" + SVG + "\n```\n", false, new URL("http://127.0.0.1:5173/"));
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".cv-codeblock")).not.toBeNull();
});

test("in the gallery the document is srcdoc behind the policy, with only the nonce'd frame script", async () => {
  await show("```svg\n" + SVG + "\n```\n", false, GALLERY);
  const iframe = frame()!;
  expect(iframe.getAttribute("sandbox")).toBe("allow-scripts");
  expect(iframe.getAttribute("src")).toBeNull();
  const srcdoc = iframe.getAttribute("srcdoc")!;
  // The policy comes first, before anything the document carries.
  expect(srcdoc.startsWith('<!doctype html><meta http-equiv="Content-Security-Policy"')).toBe(true);
  const policy = /content="([^"]*)"/.exec(srcdoc)![1]!;
  expect(policy).toContain("default-src 'none'");
  expect(policy).toContain("connect-src 'none'");
  expect(policy).toMatch(/script-src 'nonce-[0-9a-f]{32}'/);
  expect(policy).not.toMatch(/script-src[^;]*unsafe-inline/);
  expect(srcdoc).toContain(SVG);
  await post(iframe.contentWindow, { type: INLINE_PREVIEW_SIZE, height: 220 });
  expect(iframe.style.height).toBe("220px");
});

test("a gallery frame that loads a second time left its document: the card falls back to the source", async () => {
  await show("```svg\n" + SVG.replace("red", "blue") + "\n```\n", false, GALLERY);
  const iframe = frame()!;
  // Its first load is its own document (jsdom may or may not have fired it); two more are past it.
  for (const _ of [1, 2])
    await act(() => {
      iframe.dispatchEvent(new dom.window.Event("load"));
    });
  expect(frame()).toBeNull();
  expect(host.querySelector(".cv-codeblock")).not.toBeNull();
});

test("a refresh in the document is inert: the client's own metas are the only http-equiv", () => {
  const doc = inlinePreviewDocument(
    "html",
    '<META HTTP-EQUIV="refresh" content="0;url=https://example.invalid/"><p>hi</p>',
    "",
    "0123456789abcdef0123456789abcdef",
  );
  const live = [...parse(doc).querySelectorAll("meta")].filter((meta) => meta.hasAttribute("http-equiv"));
  expect(live.map((meta) => meta.getAttribute("http-equiv"))).toEqual([
    "Content-Security-Policy",
    "x-dns-prefetch-control",
  ]);
  expect(
    parse(inlinePreviewHtml("html", '<meta http-equiv="refresh" content="0">')).querySelector("meta[http-equiv]"),
  ).toBeNull();
});

test("resource hints are inert and the browser's own DNS prefetch is off", () => {
  const doc = parse(
    inlinePreviewDocument(
      "html",
      '<LINK rel="dns-prefetch" href="//a.invalid"><link/rel=preconnect href=https://b.invalid><p>hi</p>',
      "",
      "0123456789abcdef0123456789abcdef",
    ),
  );
  expect(doc.querySelectorAll("link").length).toBe(0);
  expect(doc.querySelector('meta[http-equiv="x-dns-prefetch-control"]')?.getAttribute("content")).toBe("off");
});

test("links that leave the document point nowhere, so no engine resolves their hosts", () => {
  const doc = parse(
    inlinePreviewHtml(
      "html",
      "<a href=\"https://a.invalid/x\">a</a><a HREF=//b.invalid>b</a><a href='#local'>c</a>" +
        '<a xlink:href="#x"href="https://d.invalid/">d</a>' +
        '<svg><image xlink:href="data:image/png;base64,AA=="/><use href="https://c.invalid/s.svg#i"/></svg>',
    ),
  );
  const anchors = [...doc.querySelectorAll("a")];
  expect(anchors.map((a) => a.getAttribute("href"))).toEqual(["#", "#", "#local", "#"]);
  expect(anchors[0]!.getAttribute("data-href")).toBe("https://a.invalid/x");
  expect(doc.querySelector("image")!.getAttribute("xlink:href")).toStartWith("data:image/png");
  expect(doc.querySelector("use")!.getAttribute("href")).toBe("#");
  // No link attribute anywhere still names a host.
  for (const element of doc.querySelectorAll("*"))
    for (const attribute of element.attributes)
      if (/^(xlink:)?href$/i.test(attribute.name)) expect(attribute.value).not.toContain(".invalid");
});
