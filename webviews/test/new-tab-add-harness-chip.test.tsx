// Adding a harness lives in the harness and model picker (Leo 2026-10-14): the New Tab page shows
// no "No agent to ask" row and no Integrate a harness button. With no harness installed the
// composer's chip itself says Add harness and opens the Harnesses page; with harnesses installed
// the full picker ends on an Add harness… row, reachable from the keyboard like the model rows. Since
// Leo 2026-10-20 a click on the model button opens its compact menu, whose More models submenu ends on
// Add harness… (model-menu-compact.test.tsx); the full picker here opens by its "Model" opener.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { openPicker } from "../src/agent-session/acpmux/pickerOpeners";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "MutationObserver",
] as const;
const added: string[] = [];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;
let root: Root | undefined;
let unregister = () => {};

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    MutationObserver: window.MutationObserver,
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
});

afterAll(() => {
  act(() => root?.unmount());
  unregister();
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

/// The New Tab page with the app's composer chips, once acpmux has listed `catalog` as its
/// harnesses; the Harnesses page opener counts its opens.
async function page(catalog: AcpmuxSnapshot["catalog"]) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { registerHarnessesPage } = await import("../src/agent-session/acpmux/harnesses/harnessesPage");
  const client = new QueryClient();
  // acpmux has answered with its harnesses (useHarnessesListed).
  client.setQueryData(["acpmux", "harnesses", "listed-by-test"], catalog);
  const opened = { count: 0 };
  act(() => root?.unmount());
  unregister();
  root = createRoot(host);
  await act(async () => {
    // As a mounted pane does; unregistered with the page, so no opener outlives this file.
    unregister = registerHarnessesPage(() => opened.count++);
    root!.render(
      <QueryClientProvider client={client}>
        <NewTabScreen
          snapshot={{ ...noChat(), catalog }}
          cwd="/Users/you/src/app"
          chips={NewTabComposerChips}
          onAsk={noop}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />
      </QueryClientProvider>,
    );
  });
  return opened;
}

const buttons = (scopeElement: ParentNode = host) => [...scopeElement.querySelectorAll<HTMLButtonElement>("button")];
const named = (name: string, scopeElement?: ParentNode) =>
  buttons(scopeElement).find(
    (button) => (button.getAttribute("aria-label") ?? button.textContent ?? "").trim() === name,
  );

test.serial("with no harness installed, the page has no No agent row and the chip says Add harness", async () => {
  const opened = await page([]);
  expect(host.textContent).not.toContain("No agent to ask");
  expect(named("Integrate a harness")).toBeUndefined();

  const field = host.querySelector<HTMLTextAreaElement>(".nt-field")!;
  const setValue = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), "value")!.set!;
  await act(async () => {
    setValue.call(field, "fix the flaky upload test");
    field.dispatchEvent(new window.Event("input", { bubbles: true }));
  });
  // Return with no agent to ask adds no note: the chip already says what to do.
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  });
  expect(host.textContent).not.toContain("No agent to ask");
  expect(named("Integrate a harness")).toBeUndefined();

  // Return already exercised the shared opener above. Reset the observation before checking the
  // chip itself so this assertion covers one chip click, not the two independent entry points.
  opened.count = 0;
  const chip = named("Add harness", host.querySelector(".nt-composer")!);
  expect(chip).toBeDefined();
  expect(chip!.textContent?.trim()).toBe("Add harness");
  await act(async () => chip!.click());
  expect(opened.count).toBe(1);
});

test.serial(
  "with harnesses installed, the full picker's last item is Add harness…, by click and by keyboard",
  async () => {
    const opened = await page(noChat().catalog);
    expect(named("Add harness", host.querySelector(".nt-composer")!)).toBeUndefined();
    await act(async () => void openPicker("Model"));
    const menu = host.querySelector<HTMLElement>(".acpmux-mp")!;
    expect(menu).not.toBeNull();
    const addHarness = menu.querySelector<HTMLButtonElement>(".acpmux-mp-add-harness");
    expect(addHarness?.textContent?.trim()).toBe("Add harness…");
    await act(async () => addHarness!.click());
    expect(opened.count).toBe(1);

    // From the search field, ArrowUp walks the rows back and wraps to Add harness…; Return opens it.
    await act(async () => void openPicker("Model"));
    const search = host.querySelector<HTMLInputElement>('.acpmux-mp input[role="combobox"]')!;
    const activeText = () => {
      const id = search.getAttribute("aria-activedescendant");
      return id ? host.ownerDocument.getElementById(id)?.textContent?.trim() : undefined;
    };
    for (let press = 0; press < 12 && activeText() !== "Add harness…"; press++)
      await act(async () => {
        search.dispatchEvent(new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "ArrowUp" }));
      });
    expect(activeText()).toBe("Add harness…");
    await act(async () => {
      search.dispatchEvent(new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" }));
    });
    expect(opened.count).toBe(2);
  },
);
