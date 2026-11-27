// The storefront's plan read says nothing while it is quick: its "Loading…" shows only once the read
// has lasted LOADING_SHOWN_MS, as the page's own first read does (Leo, 2026-11-14: "i also want all our
// connectivity stuff to shut the fuck up").
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { LASTING_MS, LOADING_SHOWN_MS } from "../../ui/lasting";
import { createStrings } from "../shared/i18n";
import { pageError } from "../shared/pageClient";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CloudStore } from "./store";
import { L } from "./strings";
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

/** A provider whose plan read never answers, so the storefront waits on it. */
class SilentPlanProvider extends MockCloudProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.planGet) return new Promise<R>(() => undefined);
    return super.call<R>(op, params);
  }
}

test("the storefront's plan read shows no Loading… until it lasts, then says it", async () => {
  jest.useFakeTimers();
  const store = new CloudStore(new SilentPlanProvider(), { view: "get" });
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  const loadingText = () =>
    [...rootElement.querySelectorAll(".cloud-store-no-plan")].map((node) => node.textContent ?? "").join("");
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(async () => {
      await settle();
      jest.advanceTimersByTime(LOADING_SHOWN_MS - 100);
      await settle();
    });
    expect(rootElement.querySelector(".cloud-store-sizes")).not.toBeNull();
    expect(loadingText()).not.toContain(strings.t("page.loading"));
    await act(async () => {
      jest.advanceTimersByTime(200);
      await settle();
    });
    expect(loadingText()).toContain(strings.t("page.loading"));
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});

/** A provider whose first `failures` plan reads fail with an owner error. */
class FailingPlanProvider extends MockCloudProvider {
  planReads = 0;
  constructor(private failures: number) {
    super();
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.planGet && ++this.planReads <= this.failures)
      throw pageError("cmux.cloud.upstream_error", "The Cloud service did not answer.", true);
    return super.call<R>(op, params);
  }
}

// Leo, 2026-11-22: "vacuous decisions like that should be just done". A failed plan read is read again
// on its own: no Retry button, no failure sentence while it recovers, and the sizes come once it answers.
test("a failed plan read is read again on its own, with no button, until it answers", async () => {
  jest.useFakeTimers();
  const provider = new FailingPlanProvider(2);
  const store = new CloudStore(provider, { view: "get" });
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  const sizes = () => rootElement.querySelector(".cloud-store-sizes");
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(async () => settle());
    expect(store.getSnapshot().planFailed).toBe(true);
    expect(sizes()?.querySelector("button")).toBeNull();
    expect(sizes()?.textContent).not.toContain(strings.t(L.retry));
    expect(sizes()?.querySelector(".cloud-store-no-plan")?.textContent).toBe("");
    // Jittered 1 s, then 2 s: two more reads within 4 s, the second answers.
    for (let i = 0; i < 4; i++)
      await act(async () => {
        jest.advanceTimersByTime(1_000);
        await settle();
      });
    expect(provider.planReads).toBeGreaterThanOrEqual(3);
    expect(store.getSnapshot()).toMatchObject({ planFailed: false });
    expect(store.getSnapshot().plan).toBeDefined();
    expect(rootElement.querySelector(".cloud-store-tiers")).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});

test("a plan read that keeps failing says so quietly once it lasts, still with no button", async () => {
  jest.useFakeTimers();
  const provider = new FailingPlanProvider(1_000);
  const store = new CloudStore(provider, { view: "get" });
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(async () => settle());
    for (let elapsed = 0; elapsed <= LASTING_MS; elapsed += 1_000)
      await act(async () => {
        jest.advanceTimersByTime(1_000);
        await settle();
      });
    const line = rootElement.querySelector(".cloud-store-sizes .cloud-store-no-plan");
    expect(line?.textContent).toBe(strings.t(L.storePlanStillTrying));
    expect(rootElement.querySelector(".cloud-store-sizes button")).toBeNull();
    expect(provider.planReads).toBeGreaterThan(3);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
    jest.useRealTimers();
  }
});
