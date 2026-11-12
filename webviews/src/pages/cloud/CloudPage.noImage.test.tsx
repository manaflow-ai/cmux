// "No machine image" is said once: the Cloud page and its open create sheet both got the answer and
// both said it, the sheet over the page (error-states audit, 2026-11-12).
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { CloudStore } from "./store";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  DocumentFragment: dom.window.DocumentFragment,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
// The machine list reveals its selected row; jsdom has no layout to scroll.
dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});
test("no machine image says so once: the open create sheet takes the page's line", async () => {
  const provider = new MockCloudProvider({ unsupported: [] });
  provider.noSnapshotConfigured = true;
  const store = new CloudStore(provider);
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  const lines = () => document.querySelectorAll(".cloud-blocked, .cloud-create-blocked").length;
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(settle);
    // A restore says it on the page.
    await act(async () => {
      await store.restoreSnapshot(provider.snapshots[0]!);
      await settle();
    });
    expect(document.querySelectorAll(".cloud-blocked")).toHaveLength(1);
    // Create in the sheet gets the same answer: the sheet says it, the page behind it does not.
    await act(async () => {
      store.openCreate();
      await settle();
      await store.submitCreate();
      await settle();
    });
    expect(store.getSnapshot().create?.blocked).toBe("no_snapshot_configured");
    expect(document.querySelectorAll(".cloud-create-blocked")).toHaveLength(1);
    expect(lines()).toBe(1);
    // The sheet closes: the page's line is back.
    await act(async () => {
      store.closeCreate();
      await settle();
    });
    expect(lines()).toBe(1);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
  }
});
