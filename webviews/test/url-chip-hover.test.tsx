import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle,
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});
afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

test("URL chips expose a safe hover card with a browser Open action", async () => {
  const { act } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { UiProvider } = await import("../src/ui/UiProvider");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { seedLinkStore, resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
  resetLinkStore();
  seedLinkStore({ sites: { "https://github.com/manaflow-ai/cmux/pull/21180": { title: "GitHub" } } });
  setChipHost(async (method, params) => {
    calls.push({ method, params });
    return undefined;
  });
  await act(async () => {
    root.render(
      <UiProvider container={rootElement}>
        <UrlChip href="https://github.com/manaflow-ai/cmux/pull/21180">#21180</UrlChip>
      </UiProvider>,
    );
  });
  const link = rootElement.querySelector<HTMLAnchorElement>("a.cv-chip")!;
  await act(async () => link.focus());
  const card = rootElement.querySelector<HTMLElement>(".cv-link-preview")!;
  expect(card.getAttribute("role")).toBe("dialog");
  expect(card.textContent).toContain("GitHub");
  expect(card.textContent).toContain("github.com");
  expect(card.querySelector("button")?.textContent).toContain("Open");
  await act(async () => card.querySelector<HTMLButtonElement>("button")!.focus());
  expect(rootElement.querySelector(".cv-link-preview")).not.toBeNull();
  await act(async () => card.querySelector<HTMLButtonElement>("button")!.click());
  expect(calls).toEqual([
    { method: "browser.open", params: { url: "https://github.com/manaflow-ai/cmux/pull/21180" } },
  ]);
  await act(async () => {
    card.querySelector<HTMLButtonElement>("button")!.blur();
    await new Promise((resolve) => setTimeout(resolve, 220));
  });
  expect(rootElement.querySelector(".cv-link-preview")).toBeNull();
  await act(async () => root.unmount());
  setChipHost(undefined);
});
