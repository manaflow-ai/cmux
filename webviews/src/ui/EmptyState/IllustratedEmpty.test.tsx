// l10n-allow-file: test fixtures.
// The illustrated empty state: the line, the art as decoration in a fixed box (so nothing moves
// when it loads), the one button calling its handler, and the line-only form without an image.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { IllustratedEmpty } from "./IllustratedEmpty";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("the line, a decorative image of fixed size, and a button that calls its handler", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const key of Object.keys(globals)) saved.set(key, scope[key]);
  Object.assign(scope, globals);
  let clicks = 0;
  root = createRoot(dom.window.document.getElementById("root")!);
  await act(async () =>
    root!.render(
      <IllustratedEmpty
        art="data:image/png;base64,AA=="
        artSize={48}
        line="No chats yet"
        action={{ label: "New chat", onClick: () => (clicks += 1) }}
      />,
    ),
  );
  const empty = dom.window.document.querySelector<HTMLElement>(".ui-illustrated-empty")!;
  expect(empty.dataset.layout).toBe("above");
  expect(empty.querySelector("p")?.textContent).toBe("No chats yet");
  const art = empty.querySelector("img")!;
  expect(art.getAttribute("alt")).toBe("");
  expect([art.getAttribute("width"), art.getAttribute("height")]).toEqual(["48", "48"]);
  const button = empty.querySelector<HTMLButtonElement>("button")!;
  expect(button.textContent).toBe("New chat");
  await act(async () => button.click());
  expect(clicks).toBe(1);
});

test("without art it is the line and the button alone", () => {
  const html = renderToStaticMarkup(<IllustratedEmpty line="No Results" layout="beside" />);
  expect(html).not.toContain("<img");
  expect(html).not.toContain("<button");
  expect(html).toContain('data-layout="beside"');
  expect(html).toContain("No Results");
});
