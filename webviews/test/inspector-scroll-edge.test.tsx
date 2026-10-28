import { act } from "react";
import { createRoot } from "react-dom/client";
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";
import path from "node:path";
import { ScrollEdge } from "../src/ui/ScrollEdge";

const dom = new JSDOM("<!doctype html><html><body /></html>");
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
});

test("ScrollEdge renders a CSS-only sticky boundary without scroll listeners", () => {
  const container = document.createElement("main");
  document.body.append(container);
  const root = createRoot(container);
  act(() => {
    root.render(
      <div data-scroll-edge-variant="balanced">
        <ScrollEdge>
          <span>Outputs</span>
        </ScrollEdge>
      </div>,
    );
  });
  const edge = container.querySelector<HTMLElement>(".ui-scroll-edge-fade");
  expect(edge?.textContent).toBe("Outputs");
  expect(edge?.parentElement?.dataset.scrollEdgeVariant).toBe("balanced");
  expect(edge?.getAttribute("style")).toBeNull();
  root.unmount();
});

test("scroll-edge fallback covers the host Reduce Transparency attribute", () => {
  const css = readFileSync(path.resolve(import.meta.dir, "../src/ui/scrollEdge.css"), "utf8");
  expect(css).toContain(":root[data-reduce-transparency] .ui-scroll-edge-fade");
  expect(css).toContain(":root[data-reduce-transparency] .ui-scroll-edge-fade::after");
  expect(css).toContain("backdrop-filter: none");
});
