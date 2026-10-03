// Test helpers: the page rendered on the fake transport with memory history. Import it after
// installDom() (./testDom). Not shipped (only main.tsx is bundled).
import { createMemoryHistory } from "@tanstack/react-router";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { SettingsPage } from "./components/SettingsPage";
import { FakeTransport } from "./fakeTransport";
import { SettingsStore } from "./store";
import { setLocale } from "./strings";

export type Rendered = {
  fake: FakeTransport;
  store: SettingsStore;
  container: HTMLElement;
  history: ReturnType<typeof createMemoryHistory>;
  unmount(): void;
};

export async function settle(): Promise<void> {
  await act(async () => {
    for (let index = 0; index < 5; index += 1) await Promise.resolve();
  });
}

export async function renderPage(
  options: { fake?: FakeTransport; path?: string; locale?: string } = {},
): Promise<Rendered> {
  setLocale(options.locale ?? "en");
  const fake = options.fake ?? new FakeTransport();
  const store = new SettingsStore(fake);
  store.setDomains(fake.domains);
  await store.refresh();
  const history = createMemoryHistory({ initialEntries: [options.path ?? "/settings/general"] });
  const container = document.createElement("div");
  container.id = "root";
  document.body.append(container);
  let root: Root | null = null;
  await act(async () => {
    root = createRoot(container);
    root.render(<SettingsPage store={store} history={history} />);
  });
  await settle();
  return {
    fake,
    store,
    container,
    history,
    unmount() {
      act(() => root?.unmount());
      container.remove();
      store.dispose();
    },
  };
}

export function rowElement(container: ParentNode, key: string): HTMLElement {
  const row = container.querySelector<HTMLElement>(`[data-row-key="${key}"]`);
  if (!row) throw new Error(`row ${key} is not rendered`);
  return row;
}

/** Sets a form control's value the way typing does, so React sees the change. */
export async function changeValue(element: HTMLInputElement | HTMLSelectElement, value: string): Promise<void> {
  await act(async () => {
    const proto = Object.getPrototypeOf(element) as object;
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(element, value);
    element.dispatchEvent(new window.Event(element.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
  });
  await settle();
}

export async function fire(element: Element, type: string, init: KeyboardEventInit = {}): Promise<void> {
  await act(async () => {
    const event = type.startsWith("key")
      ? new window.KeyboardEvent(type, { bubbles: true, cancelable: true, ...init })
      : new window.Event(type, { bubbles: true, cancelable: true });
    element.dispatchEvent(event);
  });
  await settle();
}

export async function click(element: Element): Promise<void> {
  await act(async () => {
    (element as HTMLElement).click();
  });
  await settle();
}

export function ops(fake: FakeTransport, op: string): unknown[] {
  return fake.log.filter((entry) => entry.op === op).map((entry) => entry.params);
}

/** Runs `work` inside act and lets the store's follow-up refresh settle. */
export async function run<T>(work: () => T | Promise<T>): Promise<T> {
  let result: T | undefined;
  await act(async () => {
    result = await work();
  });
  await settle();
  return result as T;
}
