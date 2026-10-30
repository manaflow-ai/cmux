import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { LASTING_MS } from "../src/ui/lasting";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/history/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  host = dom.window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

test("a refused history removal announces the error and keeps the timeline", async () => {
  const [
    { createRoot },
    { HistoryPage },
    { UiProvider, languageDirection },
    { createStrings },
    tableModule,
    historyModule,
    storeModule,
  ] = await Promise.all([
    import("react-dom/client"),
    import("../src/pages/history/HistoryPage"),
    import("../src/ui/UiProvider"),
    import("../src/pages/shared/i18n"),
    import("../src/pages/history/generated/strings.json"),
    import("../src/pages/history/mockProvider"),
    import("../src/pages/history/store"),
  ]);
  const { HistoryOps } = await import("../src/pages/history/types");
  class PermissionHistoryProvider extends historyModule.MockHistoryProvider {
    override async call<R>(op: string, params: unknown): Promise<R> {
      if (op === HistoryOps.remove) throw new Error("history cannot be changed");
      return super.call<R>(op, params);
    }
  }

  const provider = new PermissionHistoryProvider();
  const store = new storeModule.HistoryStore(provider, { newKey: () => "k" });
  const strings = createStrings(tableModule.default, ["en"]);
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <HistoryPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  await act(async () => store.start());

  const row = host.querySelector<HTMLElement>(".history-row")!;
  await act(async () => {
    row.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 }),
    );
  });
  const menu = dom.window.document.querySelector<HTMLElement>('[role="menu"]')!;
  const remove = [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Remove from History",
  )!;
  await act(async () => remove.click());

  expect(host.querySelector('[role="alert"].history-error')?.textContent).toBe("history cannot be changed");
  expect(host.querySelectorAll(".history-row").length).toBeGreaterThan(0);
});

test("a lost host says so once, in the page's words, not again in a banner above it", async () => {
  const [
    { createRoot },
    { HistoryPage },
    { UiProvider, languageDirection },
    { createStrings },
    tableModule,
    historyModule,
    storeModule,
  ] = await Promise.all([
    import("react-dom/client"),
    import("../src/pages/history/HistoryPage"),
    import("../src/ui/UiProvider"),
    import("../src/pages/shared/i18n"),
    import("../src/pages/history/generated/strings.json"),
    import("../src/pages/history/mockProvider"),
    import("../src/pages/history/store"),
  ]);
  const provider = new historyModule.MockHistoryProvider();
  provider.offline = true;
  const store = new storeModule.HistoryStore(provider, { newKey: () => "k" });
  const strings = createStrings(tableModule.default, ["en"]);
  act(() => root?.unmount());
  // The page's subscribe starts the store, so the grace's clock is the test's before it renders.
  jest.useFakeTimers();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <UiProvider container={host} dir={languageDirection(strings.language)}>
        <HistoryPage store={store} strings={strings} />
      </UiProvider>,
    );
  });
  jest.useFakeTimers();
  await act(async () => store.start());

  expect(store.getSnapshot().connection).toBe("disconnected");
  // Within the grace (a launch, a daemon restart) the page shows nothing (ui/lasting.ts; Leo,
  // 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD")...
  expect(host.querySelector(".history-empty")).toBeNull();
  expect(host.querySelector(".history-error")).toBeNull();
  // ...and once the link stays down past it, says so. The test moves the grace's clock.
  await act(async () => void jest.advanceTimersByTime(LASTING_MS));
  expect(host.querySelector(".history-empty")?.textContent).toBe(strings.t("page.disconnected"));
  expect(host.querySelector(".history-error")).toBeNull();
  // The page's own words are announced in place of the banner's alert: `output` is the status
  // region, which is the tag the role belongs to (jsx-a11y prefer-tag-over-role).
  expect(host.querySelector(".history-empty")?.tagName).toBe("OUTPUT");
  // Clear has nothing to reach while the host is gone, like the search field.
  const clear = [...host.querySelectorAll<HTMLButtonElement>(".history-menu-button")].find(
    (button) => button.textContent === strings.t("page.clear"),
  );
  expect(clear?.disabled).toBe(true);
  jest.useRealTimers();
});

test("a host that comes back drops the lost link's error before it re-reads", async () => {
  const [historyModule, storeModule] = await Promise.all([
    import("../src/pages/history/mockProvider"),
    import("../src/pages/history/store"),
  ]);
  const provider = new historyModule.MockHistoryProvider();
  const store = new storeModule.HistoryStore(provider, { newKey: () => "k" });
  const unsubscribe = store.subscribe(() => {});
  await store.start();
  provider.offline = true;
  provider.page.setConnected(false);
  store.setText("atlas");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(store.getSnapshot()).toMatchObject({ connection: "disconnected" });
  expect(store.getSnapshot().error).toBeDefined();
  provider.offline = false;
  provider.page.setConnected(true);
  // While the re-read is on its way the stale error would come back as a banner and an alert.
  expect(store.getSnapshot()).toMatchObject({ connection: "connecting", error: undefined });
  unsubscribe();
});
