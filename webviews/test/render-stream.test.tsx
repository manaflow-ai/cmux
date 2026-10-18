// Partial pages stay inert until their fence closes (Lucas 2026-10-18).
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://127.0.0.1:4276/",
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
const host = dom.window.document.getElementById("root")!;
let root: Root | undefined;

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const { createRoot } = await import("react-dom/client");
const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");

beforeEach(() => {
  act(() => root?.unmount());
  root = createRoot(host);
  document.documentElement.setAttribute("data-lab-live-render", "on");
});

function draw(html: string, { closed = false, live = true, lang = "cmux-render", streaming = true } = {}) {
  document.documentElement.setAttribute("data-lab-live-render", live ? "on" : "off");
  act(() =>
    root!.render(<Markdown streaming={streaming}>{"```" + lang + "\n" + html + (closed ? "\n```" : "")}</Markdown>),
  );
}

const wait = (ms = 180) =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });

test("an open page has an inert themed preview with its title and writing note", () => {
  const html = '<title>Plan &amp; effort</title><h1>Building</h1><script>parent.alert("partial")</script>';
  document.body.style.setProperty("--agent-text", "rgb(1, 2, 3)");
  draw(html);
  const frame = host.querySelector("iframe")!;
  expect(frame).not.toBeNull();
  expect(frame.getAttribute("sandbox")).toBe("");
  expect(frame.getAttribute("sandbox")).not.toContain("allow-scripts");
  expect(frame.getAttribute("src")).toBeNull();
  expect(frame.srcdoc).toContain(html);
  expect(frame.srcdoc).toContain("--cmux-text:rgb(1, 2, 3)");
  const page = new JSDOM(frame.srcdoc).window.document;
  expect(page.querySelector('meta[http-equiv="Content-Security-Policy"]')?.getAttribute("content")).toBe(
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:",
  );
  expect(frame.srcdoc.indexOf("Content-Security-Policy")).toBeLessThan(frame.srcdoc.indexOf(html));
  expect(host.querySelector(".acpmux-render-card-title")?.textContent).toBe("Plan & effort");
  expect(host.textContent).toContain("Writing…");
  expect(frame.style.height).toBe("160px");
});

test("updates coalesce within 150 ms, retain the frame, and flush the latest page", async () => {
  draw("<p>First");
  const frame = host.querySelector("iframe")!;
  expect(frame).not.toBeNull();
  const first = frame.srcdoc;
  draw("<p>Second");
  draw("<p>Third");
  expect(host.querySelector("iframe")).toBe(frame);
  expect(frame.srcdoc).toBe(first);
  await wait();
  expect(frame.srcdoc).toContain("<p>Third");
  const third = frame.srcdoc;
  draw("<p>Fourth");
  expect(frame.srcdoc).toBe(third);
  await wait();
  expect(host.querySelector("iframe")).toBe(frame);
  expect(frame.srcdoc).toContain("<p>Fourth");
});

test("with the lab off the same open fence stays a code block", () => {
  draw("<h1>Building</h1>", { live: false });
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  expect(host.querySelector("pre")?.textContent).toContain("<h1>Building</h1>");
});

test("a steady stream advances without waiting for a pause", async () => {
  draw("<p>First");
  const frame = host.querySelector("iframe")!;
  await wait(60);
  draw("<p>Second");
  await wait(60);
  draw("<p>Third");
  await wait(60);
  expect(frame.srcdoc).toContain("<p>Third");
});

test("an empty open render starts an inert card", () => {
  draw("");
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("");
  expect(host.querySelector(".acpmux-render-card-title")?.textContent).toBe("Preview");
});

test("closing takes over immediately with the normal card while the outer card stays mounted", async () => {
  draw("<p>First");
  const card = host.querySelector(".acpmux-render-card");
  expect(card).not.toBeNull();
  const partial = host.querySelector("iframe");
  draw("<title>Finished</title><p>Complete</p>");
  draw("<title>Finished</title><p>Complete</p>", { closed: true });
  expect(host.querySelector(".acpmux-render-card") === card).toBe(true);
  expect(host.querySelector("iframe") === partial).toBe(false);
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
  expect(host.textContent).not.toContain("Writing…");
  expect([...host.querySelectorAll("button")].some((button) => button.textContent === "Stop")).toBe(true);
  expect(card?.classList.contains("is-handoff")).toBe(true);
  void act(() =>
    dom.window.dispatchEvent(
      new dom.window.MessageEvent("message", {
        source: host.querySelector("iframe")!.contentWindow,
        data: { type: "cmux-render-content-size", height: 80 },
      }),
    ),
  );
  expect(card?.classList.contains("is-handoff")).toBe(false);
  await wait();
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
});

test("a component fence shows only its first source lines until it closes", () => {
  const code =
    "// title: Choice picker\nfunction App() {\n  return <button>Pick</button>;\n}\n" + "// next line\n".repeat(20);
  draw(code, { lang: "cmux-react" });
  expect(host.querySelector("iframe")).toBeNull();
  expect(host.querySelector("pre")?.textContent).toContain("function App()");
  expect(host.querySelector("pre")?.textContent?.split("\n").length).toBeLessThanOrEqual(8);
  expect(host.querySelector(".acpmux-render-card-title")?.textContent).toBe("Choice picker");
  draw(code, { lang: "cmux-react", closed: true });
  expect(host.querySelector("iframe")?.getAttribute("sandbox")).toBe("allow-scripts");
});

test("ordinary open fences and interrupted pages keep their code presentation", () => {
  draw("const count = 1", { lang: "js" });
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
  draw("<p>Interrupted", { streaming: false });
  expect(host.querySelector(".acpmux-render-card")).toBeNull();
});
