// Every machine the plan runs at once is running: the storefront's Get and the sheet's Create still work,
// because a create there makes room by pausing a machine (the platform pauses an idle one of the person's,
// else the host asks which to pause). Nothing on the page tells the person to delete a machine.
import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { CloudStore } from "./store";

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
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

test("at the running-machines limit, Get opens the create sheet and Create is enabled", async () => {
  const provider = new MockCloudProvider({ unsupported: [] });
  provider.account.plan.max_active = provider.plan.usage.active;
  expect(provider.plan.usage.active).toBeGreaterThan(0);
  const store = new CloudStore(provider, { view: "get" });
  const rootElement = document.createElement("div");
  document.body.append(rootElement);
  const root = createRoot(rootElement);
  try {
    await act(async () => root.render(<CloudPage store={store} strings={strings} />));
    await act(settle);
    expect(store.getSnapshot().view).toBe("get");
    expect(rootElement.querySelector(".cloud-store-availability.full")).not.toBeNull();
    expect(rootElement.querySelector(".cloud-store-get-hero")).not.toBeNull();
    const get = rootElement.querySelector<HTMLButtonElement>(".cloud-store-get");
    expect(get?.disabled).toBe(false);
    await act(async () => {
      get!.click();
      await settle();
    });
    expect(store.getSnapshot().create?.memoryMb).toBeGreaterThan(0);
    expect(document.querySelector(".cloud-plan-limit.reached")).not.toBeNull();
    expect(document.querySelector<HTMLButtonElement>(".cloud-create-submit")?.disabled).toBe(false);
  } finally {
    await act(async () => root.unmount());
    rootElement.remove();
  }
});

test("no language tells the person at the limit to delete a machine", () => {
  const english = (table as Record<string, Record<string, string>>).en!;
  expect(english["create.limitReached"]).not.toMatch(/delete/i);
  expect(english["create.limitReached"]).toMatch(/paus/i);
  expect(english["store.availabilityFull"]).toMatch(/paus/i);
});
