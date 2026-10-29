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
  for (const url of trusted) {
    locate(url);
    await draw("<p>trusted preview</p>");
    expect(button("Preview")).toBeDefined();
    expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("");
  }
  // Keep the existing bundled agent host while refusing other hosts on that scheme.
  locate("cmux-agent://pane/index.html");
  await draw("<p>legacy preview</p>");
  expect(button("Preview")).toBeDefined();
  for (const url of rejected) {
    locate(url);
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

test("the shared preview independently enforces host capability and resets Run on replacement", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPreview } = await import("../src/agent-session/acpmux/conversation/SharedArtifactPreview");
  const { ranRenders } = await import("../src/agent-session/acpmux/conversation/renderFrame");
  act(() => root?.unmount());
  root = createRoot(host);
  ranRenders.clear();
  const drawPreview = (html: string) =>
    act(() => root!.render(<ArtifactPreview html={html} title="Preview" runLabel="Run" />));
  for (const url of rejected) {
    locate(url);
    drawPreview("<p>no preview capability</p>");
    expect(host.querySelector("iframe")).toBeNull();
    expect(button("Run")).toBeUndefined();
  }
  locate("cmux-page://cmux.artifacts/");
  drawPreview("<p>static preview</p>");
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("");
  const code = "<script>document.title='shared'</script>";
  drawPreview(code);
  expect(host.querySelector("iframe")).toBeNull();
  act(() => button("Run")!.click());
  const frame = host.querySelector("iframe")!;
  expect(frame.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
  expect(frame.getAttribute("srcdoc")).toBeNull();

  const sent: unknown[] = [];
  const child = frame.contentWindow!;
  child.postMessage = ((message: unknown) => sent.push(message)) as never;
  const ready = (source: unknown) => {
    const event = new dom.window.MessageEvent("message", { data: { type: "cmux-render-ready" } });
    Object.defineProperty(event, "source", { value: source });
    act(() => dom.window.dispatchEvent(event));
  };
  ready(dom.window);
  expect(sent).toEqual([]);
  ready(child);
  expect(sent).toHaveLength(1);
  expect(sent[0]).toMatchObject({ type: "cmux-render", html: code });

  drawPreview("<script>document.title='replacement'</script>");
  expect(button("Run")).toBeDefined();
  expect(host.querySelector("iframe")).toBeNull();
  // The removed frame cannot solicit another copy through the old message listener.
  ready(child);
  expect(sent).toHaveLength(1);
});

test("trusted native origins use the native endpoint even with a gallery-looking URL", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPreview } = await import("../src/agent-session/acpmux/conversation/SharedArtifactPreview");
  const { ranRenders } = await import("../src/agent-session/acpmux/conversation/renderFrame");
  for (const origin of trusted) {
    locate(`${origin}frame.html?entry=agent-pane.artifact-panel`);
    ranRenders.clear();
    act(() => root?.unmount());
    root = createRoot(host);
    act(() => root!.render(<ArtifactPreview html="<script>void 0</script>" title="Preview" runLabel="Run" />));
    act(() => button("Run")!.click());
    const frame = host.querySelector("iframe")!;
    expect(frame.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
    expect(frame.getAttribute("srcdoc")).toBeNull();
  }
});
