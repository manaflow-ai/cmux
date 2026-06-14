import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { App, diffViewerFileSearchHaystack } from "../src/App";
import { createDiffViewerStatus } from "../src/status";

type FetchMock = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> | Response;

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, any>();
for (const key of ["window", "document", "navigator", "Element", "Node", "Event", "InputEvent", "KeyboardEvent", "MouseEvent", "HTMLElement", "HTMLStyleElement", "customElements", "fetch"]) {
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
  expect(dom.window.document.getElementById("source-detail")).toBeNull();
  expect(dom.window.document.getElementById("files-sidebar")).toBeTruthy();
  expect(dom.window.document.getElementById("status-text")?.textContent).toBe("Waiting for diff");
  expect(fetched).toBe(false);
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

test("diff viewer file search indexes changed file contents", () => {
  const haystack = diffViewerFileSearchHaystack("src/search-after.ts", {
    id: "file-1",
    fileDiff: {
      hunks: [{
        additionLines: ["  return \"No matches\";"],
        deletionLines: ["  return \"No results\";"],
      }],
      newName: "src/search-after.ts",
      oldName: "src/search-before.ts",
    },
  } as any);

  expect(haystack).toContain("src/search-after.ts");
  expect(haystack).toContain("no matches");
  expect(haystack).toContain("no results");
  expect(haystack).not.toContain("undefined");
});

test("Cmd+F opens diff viewer file search, then typing targets can fall through to browser find", async () => {
  dom = createDom();
  installDomGlobals(dom, async () => new Response([
    "diff --git a/cmd-f-before.txt b/cmd-f-before.txt",
    "index 1111111..2222222 100644",
    "--- a/cmd-f-before.txt",
    "+++ b/cmd-f-before.txt",
    "@@ -1 +1 @@",
    "-before",
    "+after",
    "",
    "diff --git a/src/search-before.ts b/src/search-after.ts",
    "index 3333333..4444444 100644",
    "--- a/src/search-before.ts",
    "+++ b/src/search-after.ts",
    "@@ -1,2 +1,4 @@",
    " export function labelForResult(count: number):",
    "-  if (count === 0) return \"No results\";",
    "+  if (count === 0) {",
    "+    return \"No matches\";",
    "+  }",
    "",
  ].join("\n")));

  renderApp(
    <App
      config={{
        payload: {
          patchURL: "/patch.diff",
          shortcuts: {
            diffViewerOpenFileSearch: {
              first: { key: "f", command: true, shift: false, option: false, control: false },
            },
          },
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true })}
    />,
  );

  await waitForEffects();
  await waitFor(() => dom!.window.document.getElementById("files-count")?.textContent === "2");
  const firstCmdF = new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    code: "KeyF",
    key: "f",
    metaKey: true,
  });

  expect(dom.window.document.dispatchEvent(firstCmdF)).toBe(false);
  expect(firstCmdF.defaultPrevented).toBe(true);
  await waitFor(() => fileSearchToggle()?.getAttribute("aria-pressed") === "true");
  await waitFor(() => activeFileTreeSearchInput() != null);

  const repeatedDocumentCmdF = new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    code: "KeyF",
    key: "f",
    metaKey: true,
  });
  expect(dom.window.document.dispatchEvent(repeatedDocumentCmdF)).toBe(true);
  expect(repeatedDocumentCmdF.defaultPrevented).toBe(false);

  const repeatedCmdF = new dom.window.KeyboardEvent("keydown", {
    bubbles: true,
    cancelable: true,
    composed: true,
    code: "KeyF",
    key: "f",
    metaKey: true,
  });

  expect(activeFileTreeSearchInput()?.dispatchEvent(repeatedCmdF)).toBe(true);
  expect(repeatedCmdF.defaultPrevented).toBe(false);

  fileSearchToggle()?.click();
  await waitFor(() => fileSearchToggle()?.getAttribute("aria-pressed") === "false");
  expect(activeFileTreeSearchInput()).toBeNull();

  dom.window.document.dispatchEvent(new dom.window.CustomEvent("cmux:focus-file-search", { bubbles: true }));
  await waitFor(() => activeFileTreeSearchInput() != null);
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
  const requestAnimationFrame = (callback: FrameRequestCallback) => (
    nextDom.window.setTimeout(() => callback(nextDom.window.performance.now()), 0)
  );
  const cancelAnimationFrame = (handle: number) => nextDom.window.clearTimeout(handle);
  class TestResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  nextDom.window.requestAnimationFrame = requestAnimationFrame;
  nextDom.window.cancelAnimationFrame = cancelAnimationFrame;
  (nextDom.window as any).ResizeObserver = TestResizeObserver;
  (globalThis as any).window = nextDom.window;
  (globalThis as any).document = nextDom.window.document;
  (globalThis as any).navigator = nextDom.window.navigator;
  (globalThis as any).Element = nextDom.window.Element;
  (globalThis as any).Node = nextDom.window.Node;
  (globalThis as any).Event = nextDom.window.Event;
  (globalThis as any).InputEvent = nextDom.window.InputEvent;
  (globalThis as any).KeyboardEvent = nextDom.window.KeyboardEvent;
  (globalThis as any).MouseEvent = nextDom.window.MouseEvent;
  (globalThis as any).HTMLButtonElement = nextDom.window.HTMLButtonElement;
  (globalThis as any).HTMLDivElement = nextDom.window.HTMLDivElement;
  (globalThis as any).HTMLElement = nextDom.window.HTMLElement;
  (globalThis as any).HTMLInputElement = nextDom.window.HTMLInputElement;
  (globalThis as any).HTMLStyleElement = nextDom.window.HTMLStyleElement;
  (globalThis as any).HTMLTemplateElement = nextDom.window.HTMLTemplateElement;
  (globalThis as any).ShadowRoot = nextDom.window.ShadowRoot;
  (globalThis as any).SVGElement = nextDom.window.SVGElement;
  (globalThis as any).CustomEvent = nextDom.window.CustomEvent;
  (globalThis as any).customElements = nextDom.window.customElements;
  (nextDom.window.HTMLElement.prototype as any).attachEvent = function attachEvent(
    eventName: string,
    listener: EventListener,
  ) {
    this.addEventListener(eventName.replace(/^on/, ""), listener);
  };
  (nextDom.window.HTMLElement.prototype as any).detachEvent = function detachEvent(
    eventName: string,
    listener: EventListener,
  ) {
    this.removeEventListener(eventName.replace(/^on/, ""), listener);
  };
  (globalThis as any).requestAnimationFrame = requestAnimationFrame;
  (globalThis as any).cancelAnimationFrame = cancelAnimationFrame;
  (globalThis as any).ResizeObserver = TestResizeObserver;
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

function fileSearchToggle(): HTMLButtonElement | null | undefined {
  return dom?.window.document.querySelector<HTMLButtonElement>("#file-search-toggle");
}

function activeFileTreeSearchInput(): HTMLInputElement | null {
  const searchInput = findFileTreeSearchInput(dom?.window.document.getElementById("file-list") ?? null);
  if (!searchInput) {
    return null;
  }
  if (searchInput.closest("[data-file-tree-search-container]")?.getAttribute("data-open") !== "true") {
    return null;
  }
  const root = searchInput.getRootNode();
  if (root instanceof dom!.window.ShadowRoot) {
    return root.activeElement === searchInput ? searchInput : null;
  }
  return dom!.window.document.activeElement === searchInput ? searchInput : null;
}

function findFileTreeSearchInput(root: ParentNode | null): HTMLInputElement | null {
  if (!root) {
    return null;
  }
  const searchInput = root.querySelector("[data-file-tree-search-input]");
  if (searchInput instanceof dom!.window.HTMLInputElement) {
    return searchInput;
  }
  for (const element of root.querySelectorAll("*")) {
    const shadowSearchInput = element.shadowRoot ? findFileTreeSearchInput(element.shadowRoot) : null;
    if (shadowSearchInput) {
      return shadowSearchInput;
    }
  }
  return null;
}

function contentFilesWidth(): string | undefined {
  return dom?.window.document.getElementById("content")?.style.getPropertyValue("--cmux-diff-files-width");
}

async function waitForEffects(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
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
