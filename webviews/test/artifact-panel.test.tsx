// A reply's document in the side panel (cx-ncc.63, Claude parity): an HTML, SVG or Markdown fence has
// an Open button that opens it in the panel beside the chat; the panel draws its preview with the
// source a tab away, copies it, and closes on its button or Escape.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "KeyboardEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    KeyboardEvent: window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const button = (label: string) =>
  [...host.querySelectorAll("button")].find((element) => element.getAttribute("aria-label") === label);

test("an HTML, SVG or Markdown fence opens in the side panel; other code has no Open", async () => {
  const { createRoot } = await import("react-dom/client");
  const { OpenPreview } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const { ArtifactContext } = await import("../src/agent-session/acpmux/conversation/artifactPreview");
  const opened: unknown[] = [];
  const draw = (lang: string, code: string) =>
    act(() =>
      root!.render(
        <ArtifactContext.Provider value={(artifact) => opened.push(artifact)}>
          <OpenPreview lang={lang} code={code} />
        </ArtifactContext.Provider>,
      ),
    );

  root = createRoot(host);
  draw("html", "<h1>Hi</h1>");
  act(() => button("Open preview")!.click());
  expect(opened).toEqual([{ kind: "html", lang: "html", code: "<h1>Hi</h1>" }]);

  // An `xml` fence that holds one SVG image is an SVG.
  draw("xml", '<svg viewBox="0 0 4 4"><circle r="2"/></svg>');
  act(() => button("Open preview")!.click());
  expect(opened.at(-1)).toMatchObject({ kind: "svg" });

  draw("python", "print('hi')");
  expect(button("Open preview")).toBeUndefined();
});

test("the panel previews Markdown, shows its source on Code, copies it and closes on Escape", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  const copied: string[] = [];
  Object.defineProperty(window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  let closed = 0;
  const code = "# Release notes\n\nRetry now backs off.";

  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "markdown", lang: "markdown", code }} onClose={() => closed++} />),
  );
  const panel = host.querySelector("aside")!;
  expect(panel.getAttribute("aria-label")).toBe("Document preview");
  expect(panel.querySelector("h1")?.textContent).toBe("Release notes");
  expect(button("Preview")?.getAttribute("aria-pressed")).toBe("true");

  act(() => button("Code")!.click());
  expect(button("Code")?.getAttribute("aria-pressed")).toBe("true");
  expect(panel.querySelector("h1")).toBeNull();

  await act(async () => button("Copy")!.click());
  expect(copied).toEqual([code]);

  act(() => button("Close preview")!.click());
  expect(closed).toBe(1);
  act(() => {
    panel.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(2);
});

test("HTML on a page without the render frame shows its source only", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ArtifactPanel } = await import("../src/agent-session/acpmux/conversation/ArtifactPanel");
  act(() => root?.unmount());
  root = createRoot(host);
  act(() =>
    root!.render(<ArtifactPanel artifact={{ kind: "html", lang: "html", code: "<p>Hello</p>" }} onClose={() => {}} />),
  );
  // The test page is not the bundled pane (`cmux-agent:`), so nothing can frame the HTML.
  expect(button("Preview")).toBeUndefined();
  expect(host.querySelector("iframe")).toBeNull();
});
