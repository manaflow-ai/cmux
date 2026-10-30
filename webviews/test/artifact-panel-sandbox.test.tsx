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
  location: { protocol: "cmux-agent:", pathname: "/index.html", search: "" },
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

test("plain artifact markup previews with scripts disabled, while Run upgrades script content", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  root = createRoot(host);

  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code: "<p>plain</p>" }} onClose={() => {}} />),
  );
  const passive = host.querySelector("iframe")!;
  expect(passive.getAttribute("sandbox")).toBe("");
  expect(passive.getAttribute("src")).toBeNull();
  expect(passive.getAttribute("srcdoc")).toContain("Content-Security-Policy");

  act(() =>
    root!.render(
      <ArtifactPanel
        artifact={{ kind: "html", lang: "html", code: "<button onclick=\"this.textContent='done'\">run</button>" }}
        onClose={() => {}}
      />,
    ),
  );
  expect(button("Run")).toBeDefined();
  expect(host.querySelector("iframe")).toBeNull();
  act(() => button("Run")!.click());
  const running = host.querySelector("iframe")!;
  expect(running.getAttribute("sandbox")).toBe("allow-scripts");
  expect(running.getAttribute("src")).toBe("cmux-agent://render/artifact");
});

test("malformed handlers and encoded javascript URLs never receive automatic script capability", async () => {
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  for (const code of ['<svg/onload="for(;;){}"></svg>', '<a href="java&#x09;script:alert(1)">link</a>']) {
    act(() => root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code }} onClose={() => {}} />));
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
  }
});
