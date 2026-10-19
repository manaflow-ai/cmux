// Inline renders in a reply: an agent with no render tool writes its page in a ```cmux-render fence,
// and the closed fence draws as a render card in the transcript, the same card a render tool call
// gets (RenderCard.tsx). A fence still arriving stays code, and a page with no render frame (the dev
// server, a gallery) shows the source. The card's Open hands the page to the side panel.
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
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// The code card's highlighter (@pierre/diffs) defines its elements, which read DOM constructors, on import.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
document.documentElement.setAttribute("data-lab-live-render", "off");
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const PAGE = "<title>Desk clamp</title><canvas></canvas><script>draw()</script>";
const REPLY = `Here is the clamp:\n\n\`\`\`cmux-render\n${PAGE}\n\`\`\`\n\nRun it to turn the model.`;

const button = (label: string) =>
  [...host.querySelectorAll("button")].find(
    (element) => element.getAttribute("aria-label") === label || element.textContent === label,
  );

async function draw(markdown: string, streaming = false, open?: (artifact: unknown) => void, plainCode = false) {
  const { createRoot } = await import("react-dom/client");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(
      <ArtifactContext.Provider value={open}>
        <Markdown streaming={streaming} plainCode={plainCode}>{markdown}</Markdown>
      </ArtifactContext.Provider>,
    ),
  );
}

test("a closed cmux-render fence draws as a render card named by its page's title", async () => {
  await draw(REPLY);
  const card = host.querySelector(".acpmux-render-card");
  expect(card).not.toBeNull();
  expect(card!.querySelector(".acpmux-render-card-title")?.textContent).toBe("Desk clamp");
  // Nothing runs until the reader presses Run, as for a render tool call.
  expect(host.querySelector("iframe")).toBeNull();
  act(() => button("Show preview")!.click());
  const frame = host.querySelector("iframe")!;
  expect(frame.getAttribute("src")).toBe("cmux-agent://render/frame");
  expect(frame.getAttribute("sandbox")).toBe("allow-scripts");
  // The prose around the fence still draws.
  expect(host.textContent).toContain("Run it to turn the model.");
});

test("a cmux-render fence still arriving stays code", async () => {
  await draw(`Here is the clamp:\n\n\`\`\`cmux-render\n<title>Desk clamp</title><canvas>`, true);
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.textContent).toContain("<canvas>");
});

test("the render card's Open hands its page to the side panel", async () => {
  const opened: unknown[] = [];
  await draw(REPLY, false, (artifact) => opened.push(artifact));
  act(() => button("Open preview")!.click());
  expect(opened).toEqual([{ kind: "html", lang: "html", code: PAGE }]);
});

test("only a fence that closed draws as a card: not one in a streaming list, nor one a cut reply left open", async () => {
  // A reply that ended (cancelled or cut) with its fence still open.
  await draw(`Here is the clamp:\n\n\`\`\`cmux-render\n<title>Desk clamp</title><canvas>`);
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.textContent).toContain("<canvas>");
  // A fence inside a list item while the reply streams: only the last top-level block knows it is open.
  await draw(`- the clamp:\n\n  \`\`\`cmux-render\n  <title>Desk clamp</title><canvas>`, true);
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
});

test("a page a reply rewrites under the same title is its next version in the side panel", async () => {
  const { artifactVersions } = await import("../src/agent-session/acpmux/conversation/artifactVersions");
  const page = (body: string) => `<title>Desk clamp</title>${body}`;
  const fence = (body: string) => `\`\`\`cmux-render\n${page(body)}\n\`\`\``;
  const replies = [`First try:\n\n${fence("<p>v1</p>")}`, `Thicker jaw:\n\n${fence("<p>v2</p>")}`];
  // What a render card's Open hands the panel.
  const opened = { kind: "html" as const, lang: "html", code: page("<p>v2</p>") };
  expect(artifactVersions(replies, opened).map((version) => version.code)).toEqual([
    page("<p>v1</p>"),
    page("<p>v2</p>"),
  ]);
});

for (const [name, markdown] of [
  ["quote", `> review:\n> \`\`\`cmux-render\n> ${PAGE}\n> \`\`\``],
  ["list", `- review:\n  \`\`\`cmux-render\n  ${PAGE}\n  \`\`\``],
]) {
  test(`plainCode keeps a render fence in a ${name} as code`, async () => {
    document.documentElement.setAttribute("data-lab-live-render", "on");
    try {
      await draw(markdown!, false, undefined, true);
      expect(host.querySelector(".acpmux-render-card") === null).toBe(true);
      expect(host.querySelector("iframe") === null).toBe(true);
      expect(host.textContent).toContain(PAGE);
    } finally {
      document.documentElement.setAttribute("data-lab-live-render", "off");
    }
  });
}

test.each(["<!doctype html>", " \n<!-- page -->\n<!-- layout -->\n<!DoCtYpE html>"])(
  "heartbeat injection preserves standards mode with leading %s",
  async (prefix) => {
    const html = prefix + "<html><head><title>Standards</title></head><body>Page</body></html>";
    await draw("```cmux-render\n" + html + "\n```");
    act(() => button("Show preview")!.click());
    const frame = host.querySelector("iframe")!;
    const messages: { html: string }[] = [];
    frame.contentWindow!.postMessage = (data) => messages.push(data);
    void act(() => dom.window.dispatchEvent(new dom.window.MessageEvent("message", {
      source: frame.contentWindow,
      data: { type: "cmux-render-ready" },
    })));
    const page = new JSDOM(messages[0]!.html);
    try {
      expect(page.window.document.compatMode).toBe("CSS1Compat");
      expect(messages[0]!.html.startsWith(prefix + "<script>")).toBe(true);
      expect(page.window.document.querySelector("script")?.textContent).toContain("cmux-render-ping");
    } finally {
      page.window.close();
    }
  },
);


test("a closed code fence in a streaming list still gets its highlighted card", async () => {
  dom.reconfigure({ url: "http://localhost/" });
  try {
    await act(async () => {
      const { loadHighlightedCode } = await import("../src/agent-session/acpmux/conversation/CodeBlock");
      await loadHighlightedCode();
      await draw("- Example:\n  ```js\n  const count = 1;\n  ```\n  More:\n  ```js\n  const next =", true);
    });
    expect(host.querySelector("li diffs-container")).not.toBeNull();
    expect(host.querySelector("li .cv-codeblock")?.classList.contains("cv-codeblock--plain")).toBe(false);
  } finally {
    act(() => root?.unmount());
    root = undefined;
    dom.reconfigure({ url: "cmux-agent://pane/index.html" });
  }
});
