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

test("App copies a stage and commit command for repo-backed diffs", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });
  dom.window.document.execCommand = (command: string) => command === "copy";
  let promptCalled = false;
  (dom.window as any).prompt = () => {
    promptCalled = true;
    return null;
  };

  renderApp(
    <App
      config={{
        payload: {
          repoRoot: "/tmp/repo",
          statusMessage: "Rendered diff",
          title: "Diff",
        },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  dom.window.document.getElementById("options-button")?.click();
  await waitFor(() => Boolean(stageCommitButton()));
  stageCommitButton()?.click();
  await waitFor(() => Boolean(stageCommitDialog()));
  expect(promptCalled).toBe(false);

  const input = stageCommitInput();
  expect(input).toBeTruthy();
  changeTextareaValue(input!, "Review changes");
  submitStageCommitDialog();

  await waitFor(() => dom?.window.document.getElementById("copy-feedback")?.textContent === "Copied stage & commit command");
  expect(copyFallbackValue()).toContain("git -C '/tmp/repo' add --all");
  expect(copyFallbackValue()).toContain("Review changes");
  expect(stageCommitDialog()).toBeNull();
});

test("App hides the stage and commit command when no repository path is available", async () => {
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
  expect(stageCommitButton()).toBeUndefined();
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

function stageCommitButton(): HTMLButtonElement | undefined {
  return Array.from(dom?.window.document.querySelectorAll<HTMLButtonElement>(".menu-item") ?? [])
    .find((button) => button.textContent?.includes("Copy stage & commit command"));
}

function stageCommitDialog(): HTMLElement | null {
  return dom?.window.document.querySelector<HTMLElement>(".stage-commit-dialog") ?? null;
}

function stageCommitInput(): HTMLTextAreaElement | null {
  return dom?.window.document.querySelector<HTMLTextAreaElement>("#stage-commit-message") ?? null;
}

function submitStageCommitDialog(): void {
  stageCommitDialog()
    ?.querySelector<HTMLFormElement>("form")
    ?.dispatchEvent(new dom!.window.Event("submit", { bubbles: true, cancelable: true }));
}

function changeTextareaValue(textarea: HTMLTextAreaElement, value: string): void {
  const valueSetter = Object.getOwnPropertyDescriptor(dom!.window.HTMLTextAreaElement.prototype, "value")?.set;
  valueSetter?.call(textarea, value);
  textarea.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
}

function copyFallbackValue(): string | undefined {
  return dom?.window.document.querySelector<HTMLTextAreaElement>(".copy-fallback-textarea")?.value;
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
