import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { teardownDom } from "../../../test/support/domTeardown";
import { ProviderRehearsal } from "./ProviderRehearsal";
import { MockCloudProvider } from "./mockProvider";
import { CloudStore } from "./store";
import { CloudOps } from "./ops";
import table from "./generated/strings.json";

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
afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

test("default off makes no request; opt in runs local scenarios without changing machines", async () => {
  const prior = globalThis.cmuxExperiments;
  globalThis.cmuxExperiments = {};
  const provider = new MockCloudProvider({ signedIn: false });
  const store = new CloudStore(provider);
  const before = store.getSnapshot();
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  const render = () => root.render(<ProviderRehearsal store={store} strings={createStrings(table)} />);
  try {
    await act(async () => render());
    expect(element.textContent).toBe("");
    expect(provider.calls).toEqual([]);
    globalThis.cmuxExperiments = { "cloud-provider-rehearsal": "expanded" };
    await act(async () => render());
    const buttons = element.querySelectorAll<HTMLButtonElement>("button");
    expect(buttons.length).toBe(3);
    for (const [index, state] of ["deleted", "deleted", "orphaned"].entries()) {
      await act(async () => buttons[index]!.click());
      const result = JSON.parse(element.querySelector("pre")!.textContent!);
      expect(result.simulated).toBe(true);
      expect(result.receipts.at(-1).state).toBe(state);
    }
    expect(provider.calls.every((call) => call.op === CloudOps.providerRehearse)).toBe(true);
    expect(store.getSnapshot()).toBe(before);
    provider.failNext = CloudOps.providerRehearse;
    await act(async () => buttons[0]!.click());
    expect(element.querySelector("[role=alert]")).not.toBeNull();
    expect(element.querySelector("pre")).toBeNull();
    expect(buttons[0]!.disabled).toBe(false);
  } finally {
    await act(async () => root.unmount());
    element.remove();
    globalThis.cmuxExperiments = prior;
  }
});
