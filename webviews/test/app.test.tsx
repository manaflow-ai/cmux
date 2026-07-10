import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { App } from "../src/App";
import { createDiffViewerStatus } from "../src/status";

type FetchMock = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response> | Response;

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, any>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement", "HTMLStyleElement", "customElements", "fetch", "requestAnimationFrame", "cancelAnimationFrame"]) {
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

test("custom-scheme pending pages wait for native navigation without HTTP polling", () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/opening.html");
  let fetched = false;
  installDomGlobals(dom, () => {
    fetched = true;
    throw new Error("unexpected fetch");
  });

  renderApp(
    <App
      config={{
        payload: {
          pendingReplacement: true,
          statusMessage: "Loading diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true, pending: true })}
    />,
  );

  expect(dom.window.document.getElementById("status-text")?.textContent).toBe("Loading diff");
  expect(fetched).toBe(false);
  expect(dom.window.document.documentElement.dataset.cmuxDiffWait).toBeUndefined();
});

test("custom-scheme pending pages stream exactly one typed Rust session", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/branch.html");
  const requests: any[] = [];
  const fetched: string[] = [];
  installDomGlobals(dom, (input) => {
    fetched.push(String(input));
    return new Response("", { status: 200 });
  });
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: {
        async postMessage(request: any) {
          requests.push(request);
          if (request.method === "sessionClose") {
            return { id: request.id, version: 1, result: { type: "sessionClosed" }, error: null };
          }
          return {
            id: request.id,
            version: 1,
            result: {
              type: "sessionOpened",
              value: {
                sessionId: "01234567-89ab-cdef-0123-456789abcdef",
                patch: {
                  id: "cmux-diff-viewer://0123456789abcdef/diff-session.patch",
                  mediaType: "text/x-diff",
                  byteLength: 128,
                  revision: 1,
                },
              },
            },
            error: null,
          };
        },
      },
    },
  };

  renderApp(
    <App
      config={{
        payload: {
          capabilityToken: "0123456789abcdef",
          pendingReplacement: true,
          sessionSource: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" },
          statusMessage: "Loading diff",
          title: "Diff",
          transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true, pending: true })}
    />,
  );

  await waitFor(() => dom?.window.document.body.dataset.streamFileCount === "0");
  expect(requests.filter((request) => request.method === "sessionOpen")).toHaveLength(1);
  expect(requests[0].params.source).toEqual({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" });
  expect(fetched).toEqual(["cmux-diff-viewer://0123456789abcdef/diff-session.patch"]);
  flushSync(() => root?.unmount());
  root = null;
  await waitFor(() => requests.some((request) => request.method === "sessionClose"));
  expect(requests.filter((request) => request.method === "sessionClose")).toHaveLength(1);
});

test("typed Rust empty diffs keep the localized source-specific message", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/unstaged.html");
  let fetched = false;
  installDomGlobals(dom, () => {
    fetched = true;
    return new Response("", { status: 200 });
  });
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: {
        async postMessage(request: any) {
          return {
            id: request.id,
            version: 1,
            result: null,
            error: { code: "emptyDiff", message: "No changes to diff" },
          };
        },
      },
    },
  };

  renderApp(
    <App
      config={{
        payload: {
          capabilityToken: "0123456789abcdef",
          emptyMessage: "No unstaged changes to diff.",
          pendingReplacement: true,
          sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" },
          statusMessage: "Loading diff",
          transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true, pending: true })}
    />,
  );

  await waitFor(() => dom?.window.document.getElementById("status-text")?.textContent === "No unstaged changes to diff.");
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

function createDom(url = "http://127.0.0.1/diff"): JSDOM {
  return new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url,
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
  (globalThis as any).requestAnimationFrame = (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0);
  (globalThis as any).cancelAnimationFrame = (handle: number) => clearTimeout(handle);
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

async function waitFor(predicate: () => boolean): Promise<void> {
  const timeoutAt = Date.now() + 500;
  while (!predicate()) {
    if (Date.now() > timeoutAt) {
      throw new Error("Timed out waiting for app assertion");
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
