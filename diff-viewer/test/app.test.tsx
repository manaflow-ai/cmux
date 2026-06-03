import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { App } from "../src/App";
import { createDiffViewerStatus } from "../src/status";

let root: Root | null = null;

afterEach(() => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
});

test("App renders the React-owned shell without starting a patch fetch for status-only payloads", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/diff",
  });
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).navigator = dom.window.navigator;
  (globalThis as any).Element = dom.window.Element;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).HTMLStyleElement = dom.window.HTMLStyleElement;
  (globalThis as any).customElements = dom.window.customElements;
  let fetched = false;
  (globalThis as any).fetch = () => {
    fetched = true;
    throw new Error("unexpected fetch");
  };

  const container = dom.window.document.getElementById("root");
  expect(container).toBeTruthy();
  root = createRoot(container!);
  flushSync(() => {
    root?.render(
      <App
        config={{
          payload: {
            statusMessage: "Waiting for diff",
            title: "Diff",
          },
        }}
        initialStatus={createDiffViewerStatus("Waiting for diff", { loading: false, statusOnly: true })}
      />,
    );
  });

  expect(dom.window.document.getElementById("toolbar")).toBeTruthy();
  expect(dom.window.document.getElementById("files-sidebar")).toBeTruthy();
  expect(dom.window.document.getElementById("status-text")?.textContent).toBe("Waiting for diff");
  expect(fetched).toBe(false);
});
