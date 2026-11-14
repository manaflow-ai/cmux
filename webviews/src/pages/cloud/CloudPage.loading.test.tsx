// The Cloud page's first read says nothing while it is quick: "Loading…" shows only once the read
// has lasted LOADING_SHOWN_MS (Leo, 2026-11-05: "We don't need to have so much ceremony").
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LOADING_SHOWN_MS } from "../../ui/lasting";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CloudStore } from "./store";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

/// A provider whose account read never answers, so the page stays on its first load.
class SilentAuthProvider extends MockCloudProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus) return new Promise<R>(() => undefined);
    return super.call<R>(op, params);
  }
}

test("a first read shows no Loading… until it lasts, then says it", async () => {
  jest.useFakeTimers();
  const store = new CloudStore(new SilentAuthProvider());
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(async () => {
      await settle();
      jest.advanceTimersByTime(LOADING_SHOWN_MS - 100);
      await settle();
    });
    expect(rootElement.querySelector(".cloud-loading")).toBeNull();
    await act(async () => {
      jest.advanceTimersByTime(200);
      await settle();
    });
    expect(rootElement.querySelector(".cloud-loading")?.textContent).toBe(strings.t("page.loading"));
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});
