import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { App, commentNavigationPlan, recollapseExpandedContextSeparator } from "../src/App";
import { createDiffViewerStatus } from "../src/status";

type FetchMock = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> | Response;

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, any>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement", "HTMLStyleElement", "customElements", "fetch"]) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

test("App renders the React-owned shell without starting a patch fetch for status-only payloads", async () => {
  dom = createDom();
  let fetched = false;
  installDomGlobals(dom, () => {
    fetched = true;
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          statusMessage: "Waiting for diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Waiting for diff", { loading: false, statusOnly: true })}
    />,
  );

  expect(dom.window.document.getElementById("toolbar")).toBeTruthy();
  expect(dom.window.document.querySelector("#review-tabs [aria-selected='true']")?.textContent).toContain("Review");
  expect(dom.window.document.getElementById("commit-or-push-button")?.getAttribute("disabled")).not.toBeNull();
  expect(dom.window.document.getElementById("create-pr-button")?.getAttribute("disabled")).not.toBeNull();
  expect(dom.window.document.getElementById("checks-status")?.textContent).toContain("Checks unavailable");
  expect(dom.window.document.getElementById("source-detail")).toBeNull();
  expect(dom.window.document.getElementById("files-sidebar")).toBeTruthy();
  expect(dom.window.document.getElementById("status-text")?.textContent).toBe("Waiting for diff");
  expect(fetched).toBe(false);
});

test("App surfaces check status from payload data", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          checks: [
            { name: "lint", conclusion: "success" },
            { name: "tests", status: "queued" },
          ],
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  const checks = dom.window.document.getElementById("checks-status");
  expect(checks?.getAttribute("data-status")).toBe("pending");
  expect(checks?.textContent).toContain("Checks pending");
  expect(checks?.textContent).toContain("1/2");
});

test("App treats skipped and neutral checks as terminal non-failing results", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          checks: [
            { name: "lint", conclusion: "success" },
            { name: "docs", conclusion: "skipped" },
            { name: "review", conclusion: "neutral" },
          ],
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  const checks = dom.window.document.getElementById("checks-status");
  expect(checks?.getAttribute("data-status")).toBe("pass");
  expect(checks?.textContent).toContain("Checks passing");
  expect(checks?.textContent).toContain("3/3");
});

test("context separator click passes through when the hunk is not already expanded", () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });
  const harness = contextSeparatorToggleHarness();

  const handled = recollapseExpandedContextSeparator(harness.event, harness.codeView);

  expect(handled).toBe(false);
  expect(harness.preventDefaultCount()).toBe(0);
  expect(harness.stopPropagationCount()).toBe(0);
  expect(harness.stopImmediatePropagationCount()).toBe(0);
  expect(harness.instanceChangedCount()).toBe(0);
});

test("context separator click re-collapses an already expanded hunk", () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });
  const harness = contextSeparatorToggleHarness({ fromEnd: 10, fromStart: 0 });

  const handled = recollapseExpandedContextSeparator(harness.event, harness.codeView);

  expect(handled).toBe(true);
  expect(harness.expandedHunks.has(4)).toBe(false);
  expect(harness.renderCacheCleared()).toBe(true);
  expect(harness.forceRenderOverride()).toBe(true);
  expect(harness.resetLayoutOptions()).toEqual({ includeEstimatedHeights: true });
  expect(harness.instanceChangedCount()).toBe(1);
  expect(harness.instanceChangedLayoutDirty()).toBe(true);
  expect(harness.preventDefaultCount()).toBe(1);
  expect(harness.stopPropagationCount()).toBe(1);
  expect(harness.stopImmediatePropagationCount()).toBe(1);
});

test("comment navigation switches file tabs when the target is filtered out", () => {
  const entry = {
    anchor: { line: 12, state: "anchored" },
    comment: { id: "comment-1", side: "additions" },
    itemId: "file-b",
    pending: false,
  } as any;
  const items = [{ id: "file-a" }, { id: "file-b" }] as any;

  expect(commentNavigationPlan(entry, items, "")).toEqual({
    shouldOpenFileTab: false,
    targetItemId: "file-b",
  });
  expect(commentNavigationPlan(entry, items, "file-a")).toEqual({
    shouldOpenFileTab: true,
    targetItemId: "file-b",
  });
  expect(commentNavigationPlan(entry, items, "file-b")).toEqual({
    shouldOpenFileTab: false,
    targetItemId: "file-b",
  });
  expect(commentNavigationPlan({ ...entry, itemId: null }, items, "file-a")).toBeNull();
});

test("App still starts diff rendering when statusMessage is an empty string", async () => {
  dom = createDom();
  let fetchCount = 0;
  installDomGlobals(dom, () => {
    fetchCount += 1;
    return new Response("", { status: 200 });
  });

  renderApp(
    <App
      config={{
        payload: {
          patchURL: "/patch.diff",
          statusMessage: "",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("", { loading: true })}
    />,
  );

  await waitFor(() => fetchCount > 0);
  expect(fetchCount).toBe(1);
});

test("App reports copy failure without replacing the current status screen", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  dom.window.document.getElementById("options-button")?.click();
  await waitFor(() => Boolean(copyGitApplyButton()));
  const copyButton = copyGitApplyButton();
  copyButton?.click();

  await waitFor(() => dom?.window.document.getElementById("copy-feedback")?.textContent === "Could not copy git apply command.");
  expect(dom.window.document.getElementById("status-text")?.textContent).toBe("Rendered diff");
});

test("files sidebar width can be changed from the resize separator", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  const handle = dom.window.document.getElementById("files-resize-handle");
  expect(handle).toBeTruthy();
  handle?.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "ArrowLeft" }));

  await waitFor(() => contentFilesWidth() === "272px");
});

test("layout toggle persists user choice while explicit payload layout wins", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          layout: "unified",
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  expect(dom.window.document.documentElement.dataset.layout).toBe("unified");
  dom.window.document.getElementById("layout-toggle")?.click();
  await waitFor(() => dom?.window.localStorage.getItem("cmux.diffViewer.layout") === "split");
  expect(dom.window.document.documentElement.dataset.layout).toBe("split");
  flushSync(() => root?.unmount());
  root = null;

  renderApp(
    <App
      config={{
        payload: {
          layout: "unified",
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  expect(dom.window.document.documentElement.dataset.layout).toBe("split");
  flushSync(() => root?.unmount());
  root = null;

  renderApp(
    <App
      config={{
        payload: {
          layout: "unified",
          layoutSource: "explicit",
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  expect(dom.window.document.documentElement.dataset.layout).toBe("unified");
});

function createDom(): JSDOM {
  return new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/diff",
  });
}

function installDomGlobals(nextDom: JSDOM, fetchImpl: FetchMock): void {
  (globalThis as any).window = nextDom.window;
  (globalThis as any).document = nextDom.window.document;
  (globalThis as any).navigator = nextDom.window.navigator;
  (globalThis as any).Element = nextDom.window.Element;
  (globalThis as any).Node = nextDom.window.Node;
  (globalThis as any).HTMLElement = nextDom.window.HTMLElement;
  (globalThis as any).HTMLStyleElement = nextDom.window.HTMLStyleElement;
  (globalThis as any).customElements = nextDom.window.customElements;
  (globalThis as any).fetch = fetchImpl;
}

function renderApp(element: React.ReactNode): void {
  const container = dom?.window.document.getElementById("root");
  expect(container).toBeTruthy();
  root = createRoot(container!);
  flushSync(() => {
    root?.render(element);
  });
}

function copyGitApplyButton(): HTMLButtonElement | undefined {
  return Array.from(dom?.window.document.querySelectorAll<HTMLButtonElement>(".menu-item") ?? [])
    .find((button) => button.textContent?.includes("Copy git apply command"));
}

function contentFilesWidth(): string | undefined {
  return dom?.window.document.getElementById("content")?.style.getPropertyValue("--cmux-diff-files-width");
}

function contextSeparatorToggleHarness(region?: { fromEnd?: number; fromStart?: number }) {
  const itemElement = dom!.window.document.createElement("diffs-container");
  const separator = dom!.window.document.createElement("div");
  const control = dom!.window.document.createElement("span");
  separator.setAttribute("data-expand-index", "4");
  control.setAttribute("data-unmodified-lines", "");
  separator.appendChild(control);
  itemElement.appendChild(separator);
  dom!.window.document.body.appendChild(itemElement);

  const expandedHunks = new Map<number, { fromEnd?: number; fromStart?: number }>();
  if (region) {
    expandedHunks.set(4, region);
  }
  let renderCacheCleared = false;
  let resetLayoutOptions: { includeEstimatedHeights?: boolean } | undefined;
  let instanceChangedCount = 0;
  let instanceChangedLayoutDirty = false;
  let preventDefaultCount = 0;
  let stopPropagationCount = 0;
  let stopImmediatePropagationCount = 0;
  const instance: any = {
    forceRenderOverride: false,
    hunksRenderer: {
      clearRenderCache: () => {
        renderCacheCleared = true;
      },
      getExpandedHunksMap: () => expandedHunks,
    },
    resetLayoutCache: (options?: { includeEstimatedHeights?: boolean }) => {
      resetLayoutOptions = options;
    },
  };
  const codeView: any = {
    getInstance: () => ({
      getRenderedItems: () => [{ element: itemElement, instance, type: "diff" }],
      instanceChanged: (_instance: any, layoutDirty: boolean) => {
        expect(_instance).toBe(instance);
        instanceChangedCount += 1;
        instanceChangedLayoutDirty = layoutDirty;
      },
    }),
  };
  return {
    codeView,
    event: {
      nativeEvent: {
        composedPath: () => [control, separator, itemElement],
        stopImmediatePropagation: () => {
          stopImmediatePropagationCount += 1;
        },
      } as any,
      preventDefault: () => {
        preventDefaultCount += 1;
      },
      stopPropagation: () => {
        stopPropagationCount += 1;
      },
    },
    expandedHunks,
    forceRenderOverride: () => instance.forceRenderOverride,
    instanceChangedCount: () => instanceChangedCount,
    instanceChangedLayoutDirty: () => instanceChangedLayoutDirty,
    preventDefaultCount: () => preventDefaultCount,
    renderCacheCleared: () => renderCacheCleared,
    resetLayoutOptions: () => resetLayoutOptions,
    stopImmediatePropagationCount: () => stopImmediatePropagationCount,
    stopPropagationCount: () => stopPropagationCount,
  };
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const timeoutAt = Date.now() + 500;
  while (!predicate()) {
    if (Date.now() > timeoutAt) {
      throw new Error("Timed out waiting for app assertion");
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
