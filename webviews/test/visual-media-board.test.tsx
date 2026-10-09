// The visual media board is a scan surface, so its filtering and playback controls need a
// deterministic DOM contract in addition to the rendered gallery specimen.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { VisualMediaBoard } from "../src/gallery/fixtures/VisualMediaBoard";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("filters report the visible media and expose pressed state", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<VisualMediaBoard />);
  });

  const buttons = () => [...container.querySelectorAll<HTMLButtonElement>(".cmux-gallery-media-filter button")];
  const count = () => container.querySelector(".cmux-gallery-media-count-label")?.textContent;
  const choose = async (label: string) => {
    const button = buttons().find((candidate) => candidate.textContent === label);
    expect(button).toBeDefined();
    await act(async () => button!.click());
  };

  expect(count()).toBe("6 previews · 3 motion");
  expect(
    buttons()
      .find((button) => button.textContent === "All")
      ?.getAttribute("aria-pressed"),
  ).toBe("true");

  await choose("Static");
  expect(count()).toBe("3 previews · 0 motion");
  expect(container.querySelectorAll(".cmux-gallery-media-card")).toHaveLength(3);
  expect(
    buttons()
      .find((button) => button.textContent === "Static")
      ?.getAttribute("aria-pressed"),
  ).toBe("true");

  await choose("Motion");
  expect(count()).toBe("3 previews · 3 motion");
  expect(container.querySelectorAll(".cmux-gallery-media-card")).toHaveLength(3);
});

test("fit controls expose the selected crop mode", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(<VisualMediaBoard />);
  });
  const fitButtons = () =>
    [...container.querySelectorAll<HTMLButtonElement>(".cmux-gallery-media-filter button")].filter(
      (button) => button.textContent === "cover" || button.textContent === "contain",
    );
  expect(
    fitButtons()
      .find((button) => button.textContent === "cover")
      ?.getAttribute("aria-pressed"),
  ).toBe("true");
  await act(async () =>
    fitButtons()
      .find((button) => button.textContent === "contain")!
      .click(),
  );
  expect(
    fitButtons()
      .find((button) => button.textContent === "contain")
      ?.getAttribute("aria-pressed"),
  ).toBe("true");
});
