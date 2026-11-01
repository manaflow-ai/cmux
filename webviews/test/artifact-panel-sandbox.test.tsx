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
  // Passive markup draws in the native artifact frame, whose host refuses every navigation after its
  // own first request (AgentPaneNavigation.swift, PageArtifactFrame.swift), as the inline preview does
  // (InlinePreview.tsx); its scripts stay off because markup that carries one waits for Run.
  const passive = host.querySelector("iframe")!;
  expect(passive.getAttribute("sandbox")).toBe("allow-scripts");
  expect(passive.getAttribute("src")).toBe("cmux-agent://render/artifact");
  expect(passive.getAttribute("srcdoc")).toBeNull();

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

test("the shared page host previews passive HTML and SVG and grants scripts only after Run", async () => {
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const previous = scope.location;
  scope.location = new URL("cmux-page://cmux.agent/");
  try {
    for (const kind of ["html", "svg"] as const) {
      act(() =>
        root!.render(
          <ArtifactPanel
            artifact={{ kind, lang: kind, code: kind === "html" ? "<p>shared</p>" : "<svg/>" }}
            onClose={() => {}}
          />,
        ),
      );
      expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
      expect(host.querySelector("iframe")?.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
    }
    act(() =>
      root!.render(
        <ArtifactPanel
          artifact={{ kind: "html", lang: "html", code: '<button onclick="this.textContent++">10</button>' }}
          onClose={() => {}}
        />,
      ),
    );
    expect(host.querySelector("iframe")).toBeNull();
    act(() => button("Run")!.click());
    expect(host.querySelector("iframe")?.getAttribute("src")).toBe("cmux-page://cmux.agent/__artifact");
    expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
    act(() =>
      root!.render(
        <ArtifactPanel
          artifact={{ kind: "html", lang: "jsx", code: "<button>shared JSX</button>" }}
          onClose={() => {}}
        />,
      ),
    );
    expect(button("Run")).toBeDefined();
    expect(host.querySelector("iframe")).toBeNull();
  } finally {
    scope.location = previous;
  }
});

test("render-card versions retain the original CDN-capable render endpoint", async () => {
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const code = '<script src="https://cdn.jsdelivr.net/npm/chart.js"></script><canvas id="chart"></canvas>';
  const versions = [code, code + '<script>new Chart(document.getElementById("chart"), {})</script>'].map((code) => ({
    kind: "html" as const,
    lang: "html",
    code,
    render: "chart-tool",
  }));
  act(() => root!.render(<ArtifactPanel artifact={versions[0]!} versions={versions} onClose={() => {}} />));
  act(() => button("Run")!.click());
  expect(host.querySelector("iframe")?.getAttribute("src")).toBe("cmux-agent://render/frame");
  act(() => button("Next version")!.click());
  act(() => button("Run")!.click());
  expect(host.querySelector("iframe")?.getAttribute("src")).toBe("cmux-agent://render/frame");
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
});

/// The document the native frame is sent once it says it is ready (RenderCard.tsx useRenderFrame).
function sentDocument(frame: HTMLIFrameElement): string | undefined {
  const target = frame.contentWindow!;
  let sent: string | undefined;
  target.postMessage = ((message: { type?: string; html?: string }) => {
    if (message?.type === "cmux-render") sent = message.html;
  }) as typeof target.postMessage;
  act(() => {
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", { data: { type: "cmux-render-ready" }, source: target }),
    );
  });
  return sent;
}

const OUTBOUND =
  '<meta http-equiv="refresh" content="0;url=https://probe.invalid/refresh">' +
  '<link rel="dns-prefetch" href="https://probe.invalid/">' +
  '<a id="out" href="https://probe.invalid/link">out</a><a href="#in" id="in">in</a>' +
  '<svg><a xlink:href="https://probe.invalid/svg"><text>x</text></a></svg>';

test("the side panel's passive frame is sent the inert document: no refresh, no resource hint, no link out", async () => {
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code: OUTBOUND }} onClose={() => {}} />),
  );
  const frame = host.querySelector("iframe")!;
  expect(frame.getAttribute("src")).toBe("cmux-agent://render/artifact");
  const html = sentDocument(frame);
  expect(html).toBeDefined();
  expect(html).not.toMatch(/\shttp-equiv=/i);
  expect(html).not.toMatch(/<link[\s/>]/i);
  expect(html).not.toMatch(/\s(?:xlink:)?href="https:/i);
  expect(html).toContain('href="#in"');
});

test("the gallery's passive frame runs only its own nonce'd guard script, and leaving its document shows the source", async () => {
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const previous = scope.location;
  scope.location = new URL("http://localhost/gallery/frame.html?entry=artifact-panel");
  try {
    act(() =>
      root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code: OUTBOUND }} onClose={() => {}} />),
    );
    const frame = host.querySelector("iframe")!;
    expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
    const srcdoc = frame.getAttribute("srcdoc")!;
    const nonce = /script-src 'nonce-([0-9a-f]{32})'/.exec(srcdoc)?.[1];
    expect(nonce).toBeDefined();
    expect(srcdoc).toContain(`<script nonce="${nonce}">`);
    expect(srcdoc).not.toContain("'unsafe-inline'; style-src");
    expect(srcdoc).not.toMatch(/\shttp-equiv="refresh"/i);
    expect(srcdoc).not.toMatch(/\s(?:xlink:)?href="https:/i);
    // The first load is its document; a second means it navigated away, so the source shows instead.
    act(() => void frame.dispatchEvent(new dom.window.Event("load")));
    expect(host.querySelector("iframe")).not.toBeNull();
    act(() => void frame.dispatchEvent(new dom.window.Event("load")));
    expect(host.querySelector("iframe")).toBeNull();
    expect(host.querySelector(".acpmux-artifact-body")?.textContent).toContain("probe.invalid/link");
  } finally {
    scope.location = previous;
  }
});
