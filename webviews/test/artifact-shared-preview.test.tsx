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
  location: dom.window.location,
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
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
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

const button = (label: string) =>
  [...host.querySelectorAll("button")].find(
    (element) => element.getAttribute("aria-label") === label || element.textContent === label,
  );

const trusted = ["cmux-page://cmux.agent/", "cmux-page://cmux.artifacts/"];
const rejected = [
  "cmux-page://cmux.files/",
  "cmux-page://cmux.agent.evil/",
  "cmux-page://cmux.artifacts.evil/",
  "cmux-page://cmux.agent:1234/",
  "cmux-page://user@cmux.agent/",
  "cmux-page://user:secret@cmux.artifacts/",
  "https://cmux.agent/",
  "http://localhost/",
  "file:///cmux.artifacts/index.html",
  "cmux-agent://render/artifact",
  "cmux-agent://untrusted/",
];
const locate = (url: string) => {
  dom.reconfigure({ url });
  scope.location = dom.window.location;
};
async function draw(code: string) {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  if (!root) root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactPanel key={location.href} artifact={{ kind: "html", lang: "html", code }} onClose={() => {}} />,
    ),
  );
}

test("exact agent and artifacts page origins have native rendering; other origins do not", async () => {
  const { canRender } = await import("../src/agent-session/acpmux/conversation/RenderCard");
  for (const url of trusted) {
    locate(url);
    expect([url, canRender()]).toEqual([url, true]);
  }
  // Keep the existing bundled agent host while refusing other hosts on that scheme.
  locate("cmux-agent://pane/index.html");
  expect(canRender()).toBe(true);
  for (const url of rejected) {
    locate(url);
    expect([url, canRender()]).toEqual([url, false]);
    await draw("<p>untrusted preview</p>");
    expect(button("Preview")).toBeUndefined();
    expect(host.querySelector("iframe")).toBeNull();
  }
});

for (const url of trusted) {
  test(`${url} keeps passive markup scriptless and requires Run for every new document`, async () => {
    const { ranRenders } = await import("../src/agent-session/acpmux/conversation/RenderCard");
    ranRenders.clear();
    locate(url);
    await draw("<p>passive</p>");
    const passive = host.querySelector("iframe");
    expect(passive).not.toBeNull();
    expect(passive!.getAttribute("sandbox")).toBe("");
    expect(passive!.getAttribute("src")).toBeNull();
    expect(passive!.getAttribute("srcdoc")).toContain("connect-src 'none'");

    const code = "<script>document.body.textContent='one'</script>";
    await draw(code);
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
    act(() => button("Run")!.click());
    const running = host.querySelector("iframe")!;
    expect(running.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
    expect(running.getAttribute("sandbox")).toBe("allow-scripts");
    expect(running.getAttribute("srcdoc")).toBeNull();

    // Existing permission survives an ordinary remount, but never grants a changed document Run.
    act(() => root!.unmount());
    root = undefined;
    await draw(code);
    expect(host.querySelector("iframe")?.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
    await draw("<script>document.body.textContent='two'</script>");
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
    // A fresh page's empty permission cache starts behind Run again.
    act(() => root!.unmount());
    root = undefined;
    ranRenders.clear();
    await draw(code);
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
  });
}
