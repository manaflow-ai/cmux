import { afterAll, beforeAll, expect, jest, test } from "bun:test";
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
  // A pull request's card is named by its reference: its page title ("GitHub" here) only repeats
  // the pull request's own title, and cmux has no title for it yet.
  expect(card.getAttribute("aria-label")).toBe("manaflow-ai/cmux#21180");
  expect(card.querySelector(".cv-link-preview__site")?.textContent).toBe("manaflow-ai/cmux#21180");
  expect(card.textContent).not.toContain("GitHub");
  expect(card.querySelector("button")?.textContent).toContain("Open");
  await act(async () => card.querySelector<HTMLButtonElement>("button")!.focus());
  expect(rootElement.querySelector(".cv-link-preview")).not.toBeNull();
  await act(async () => card.querySelector<HTMLButtonElement>("button")!.click());
  // The chip asked the host's cache for its mark's state colour; its card then asked gh about it
  // (chips/PullRequestCard.tsx).
  expect(calls).toEqual([
    { method: "pr.inspect", params: { url: "https://github.com/manaflow-ai/cmux/pull/21180", cached: true } },
    { method: "pr.inspect", params: { url: "https://github.com/manaflow-ai/cmux/pull/21180" } },
    // Not `browser.open`, which the host takes only for a turn's local preview page.
    { method: "browser.openIn", params: { url: "https://github.com/manaflow-ai/cmux/pull/21180", browserId: "cmux" } },
  ]);
  // Focus leaving: the card goes after its grace, on a fake clock.
  const { HOVER_INTENT } = await import("../src/ui/hoverIntent");
  jest.useFakeTimers();
  try {
    await act(async () => card.querySelector<HTMLButtonElement>("button")!.blur());
    await act(async () => void jest.advanceTimersByTime(HOVER_INTENT.cardGrace - 1));
    expect(rootElement.querySelector(".cv-link-preview")).not.toBeNull();
    await act(async () => void jest.advanceTimersByTime(41));
  } finally {
    jest.useRealTimers();
  }
  expect(rootElement.querySelector(".cv-link-preview")).toBeNull();
  await act(async () => root.unmount());
  setChipHost(undefined);
});

test("link inspection bounds burst requests and coalesces store notifications", async () => {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { resetLinkStore, seedLinkStore, usePathInfo, useSiteInfo } =
    await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const rootElement = dom.window.document.getElementById("root")!;
  const root = createRoot(rootElement);
  const paths = Array.from({ length: 65 }, (_, index) => `/workspace/file-${index}.md`);
  const urls = Array.from({ length: 65 }, (_, index) => `https://example.com/page-${index}`);
  const calls: Array<{ paths: string[]; urls: string[] }> = [];
  const pending: Array<{ resolve: (value: unknown) => void }> = [];
  let inFlight = 0;
  let maxInFlight = 0;
  let renders = 0;

  function Probe() {
    renders += 1;
    const pathInfo = paths.map((path) => usePathInfo(path).info?.place ?? "pending");
    const siteInfo = urls.map((url) => useSiteInfo(url)?.title ?? "pending");
    return createElement("output", {
      "data-state": `${pathInfo[0]}|${pathInfo[64]}|${siteInfo[0]}|${siteInfo[64]}`,
    });
  }

  resetLinkStore();
  setChipHost(async (method, params) => {
    expect(method).toBe("link.inspect");
    const batch = params as { paths: string[]; urls: string[] };
    calls.push(batch);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    return new Promise((resolve) => {
      pending.push({
        resolve: (value) => {
          inFlight -= 1;
          resolve(value);
        },
      });
    });
  });

  await act(async () => {
    root.render(createElement(Probe));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toHaveLength(1);
  expect(calls[0]).toMatchObject({ paths: paths.slice(0, 64), urls: urls.slice(0, 64) });
  expect(maxInFlight).toBe(1);

  await act(async () => {
    pending.shift()!.resolve({
      paths: { [paths[0]]: { place: "root", folder: false } },
      sites: { [urls[0]]: { title: "First" } },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(calls).toHaveLength(2);
  expect(calls[1]).toMatchObject({ paths: paths.slice(64), urls: urls.slice(64) });
  expect(maxInFlight).toBe(1);
  expect(rootElement.querySelector("output")?.getAttribute("data-state")).toBe("root|pending|First|pending");

  await act(async () => {
    pending.shift()!.resolve({
      paths: { [paths[64]]: { place: "outside", folder: false } },
      sites: { [urls[64]]: { title: "Last" } },
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(inFlight).toBe(0);
  expect(rootElement.querySelector("output")?.getAttribute("data-state")).toBe("root|outside|First|Last");

  const beforeSeedRenders = renders;
  // Two answers for keys the probe reads, in one tick: one render. (A key no hook reads renders
  // nothing: each hook's snapshot is its own key.)
  seedLinkStore({ paths: { [paths[1]]: { place: "root", folder: false } } });
  seedLinkStore({ sites: { [urls[1]]: { title: "Seed" } } });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(renders - beforeSeedRenders).toBe(1);

  await act(async () => root.unmount());
  setChipHost(undefined);
});
