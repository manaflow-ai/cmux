// The live preview card's exit and its frame swap (cardMotion.ts), in a DOM: the card stays drawn
// while its exit plays and goes when that ends, or at once with no exit (motion off); a new frame
// shows only once it has decoded.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ComputerUsePreviewCard } from "./ComputerUsePreviewCard";
import type { ComputerUsePreview } from "./computerUsePreview";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "Image",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Image: undefined,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

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

const frame = "data:image/png;base64,AA==";
const running: ComputerUsePreview = { session: "cua_t1", app: "Calculator", done: false, frame };

async function render(container: HTMLElement, preview: ComputerUsePreview | null) {
  await act(async () => {
    root ??= createRoot(container);
    root.render(<ComputerUsePreviewCard preview={preview} onOpen={() => undefined} onClose={() => undefined} />);
  });
}

/// One running exit transition on every element, ended by `end()`.
function stubExit(): { end(): void } {
  let end = () => {};
  const finished = new Promise<void>((resolve) => {
    end = resolve;
  });
  (dom!.window.Element.prototype as unknown as { getAnimations(): unknown[] }).getAnimations = () => [{ finished }];
  return { end };
}

const card = (container: HTMLElement) => container.querySelector(".acpmux-cu-preview");

test("the card stays drawn, leaving and inert, until its exit ends", async () => {
  const container = installDom();
  await render(container, running);
  expect(card(container)?.hasAttribute("data-leaving")).toBe(false);
  const exit = stubExit();
  await render(container, null);
  expect(card(container)?.hasAttribute("data-leaving")).toBe(true);
  expect(card(container)?.hasAttribute("inert")).toBe(true);
  expect(container.querySelector("img")?.getAttribute("src")).toBe(frame);
  await act(async () => exit.end());
  expect(card(container)).toBe(null);
});

test("with motion off (no exit transition) the card goes at once", async () => {
  const container = installDom();
  (dom!.window.Element.prototype as unknown as { getAnimations(): unknown[] }).getAnimations = () => [];
  await render(container, running);
  await render(container, null);
  expect(card(container)).toBe(null);
});

test("a card that comes back during the exit stays", async () => {
  const container = installDom();
  await render(container, running);
  const exit = stubExit();
  await render(container, null);
  const next = { ...running, session: "cua_t2" };
  await render(container, next);
  await act(async () => exit.end());
  expect(card(container)?.hasAttribute("data-leaving")).toBe(false);
  expect(container.querySelector("button")?.getAttribute("aria-label")).toBe(
    "Calculator, live. Open in Agent Activity",
  );
});

test("a new frame shows only once it has decoded, and the one before stays until then", async () => {
  const container = installDom();
  const decodes: (() => void)[] = [];
  scope.Image = class {
    src = "";
    decode() {
      return new Promise<void>((resolve) => decodes.push(resolve));
    }
  };
  await render(container, running);
  const img = () => container.querySelector(".acpmux-cu-preview__frame > img")?.getAttribute("src");
  expect(img()).toBe(frame);
  const second = "data:image/png;base64,AQ==";
  const third = "data:image/png;base64,Ag==";
  await render(container, { ...running, frame: second });
  expect(img()).toBe(frame);
  await render(container, { ...running, frame: third });
  // The newer frame decodes first; the older one, finishing later, never replaces it.
  await act(async () => decodes.at(-1)!());
  expect(img()).toBe(third);
  await act(async () => decodes.at(-2)!());
  expect(img()).toBe(third);
});
