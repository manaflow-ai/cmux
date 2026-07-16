import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { adjacentItemId, App, visibleItemId } from "../src/App";
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
  const commentRequests: any[] = [];
  const fetched: string[] = [];
  let releaseSecondSession: (() => void) | undefined;
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
          if (requests.filter((candidate) => candidate.method === "sessionOpen").length === 2) {
            await new Promise<void>((resolve) => {
              releaseSecondSession = resolve;
            });
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
                source: request.params.source,
              },
            },
            error: null,
          };
        },
      },
      cmuxDiffComments: {
        async postMessage(request: any) {
          commentRequests.push(request);
          return { ok: true, value: { comments: [] } };
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
          sourceOptions: [
            { label: "Branch", selected: true, sessionSource: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" }, value: "branch" },
            { label: "Unstaged", selected: false, sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" }, value: "unstaged" },
            { label: "Last turn", selected: false, sessionSource: { kind: "patch", path: "/last-turn.patch" }, value: "last-turn" },
          ],
          repoOptions: [
            { label: "repo", selected: true, sessionSource: { kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" }, value: "/tmp/repo" },
            { label: "other-repo", selected: false, sessionSource: { kind: "branch", repoRoot: "/tmp/other-repo" }, value: "/tmp/other-repo" },
          ],
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
  await waitFor(() => commentRequests.length === 1);
  expect(commentRequests[0].params.repoRoot).toBe("/tmp/repo");
  expect(requests[0].params.source).toEqual({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" });
  expect(fetched).toEqual(["cmux-diff-viewer://0123456789abcdef/diff-session.patch"]);
  expect(requests.filter((request) => request.method === "sessionClose")).toHaveLength(0);
  const repoSelect = dom.window.document.getElementById("repo-select") as HTMLSelectElement;
  repoSelect.value = "/tmp/other-repo";
  repoSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 2);
  dom.window.document.getElementById("options-button")?.click();
  await waitFor(() => Boolean(copyGitApplyButton()));
  copyGitApplyButton()?.click();
  await waitFor(() => dom?.window.document.getElementById("copy-feedback")?.textContent === "Could not copy git apply command.");
  releaseSecondSession?.();
  await waitFor(() => fetched.length === 2);
  expect(requests.filter((request) => request.method === "sessionOpen")[1].params.source)
    .toEqual({ kind: "branch", repoRoot: "/tmp/other-repo" });

  const sourceSelect = dom.window.document.getElementById("source-select") as HTMLSelectElement;
  sourceSelect.value = "unstaged";
  sourceSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 3);
  await waitFor(() => fetched.length === 3);
  expect(requests.filter((request) => request.method === "sessionOpen")[2].params.source)
    .toEqual({ kind: "unstaged", repoRoot: "/tmp/other-repo" });

  repoSelect.value = "/tmp/repo";
  repoSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 4);
  await waitFor(() => fetched.length === 4);
  expect(requests.filter((request) => request.method === "sessionOpen")[3].params.source)
    .toEqual({ kind: "unstaged", repoRoot: "/tmp/repo" });

  sourceSelect.value = "last-turn";
  sourceSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 5);
  await waitFor(() => fetched.length === 5);
  expect(requests.filter((request) => request.method === "sessionOpen")[4].params.source)
    .toEqual({ kind: "patch", path: "/last-turn.patch" });
  const closeCountBeforePageHide = requests.filter((request) => request.method === "sessionClose").length;
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  await waitFor(() => requests.filter((request) => request.method === "sessionClose").length > closeCountBeforePageHide);
  flushSync(() => root?.unmount());
  root = null;
  expect(requests.filter((request) => request.method === "sessionClose").length)
    .toBeGreaterThan(closeCountBeforePageHide);
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

test("typed branch empty diffs keep the base picker available before base resolution", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/branch.html");
  installDomGlobals(dom, () => new Response("", { status: 200 }));
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: {
        async postMessage(request: any) {
          if (request.method === "sessionOpen") {
            return {
              id: request.id,
              version: 1,
              result: null,
              error: { code: "emptyDiff", message: "No changes to diff" },
            };
          }
          return {
            id: request.id,
            version: 1,
            result: { type: "branches", value: { groups: [] } },
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
          emptyMessage: "No branch changes to diff.",
          sessionSource: { kind: "branch", repoRoot: "/tmp/repo" },
          transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
        },
      }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true })}
    />,
  );

  await waitFor(() => dom?.window.document.getElementById("status-text")?.textContent === "No branch changes to diff.");
  expect(dom.window.document.querySelector(".base-picker-button")).toBeTruthy();
});

test("typed source switching preserves the last resolved branch base", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/branch.html");
  const requests: any[] = [];
  installDomGlobals(dom, () => new Response("", { status: 200 }));
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: {
        async postMessage(request: any) {
          requests.push(request);
          if (request.method === "sessionClose") {
            return { id: request.id, version: 1, result: { type: "sessionClosed" }, error: null };
          }
          const source = request.params.source.kind === "branch"
            ? {
                ...request.params.source,
                baseRef: request.params.source.baseRef
                  ?? (request.params.source.repoRoot === "/tmp/other-repo" ? "other-base" : "chosen-base"),
              }
            : request.params.source;
          return {
            id: request.id,
            version: 1,
            result: {
              type: "sessionOpened",
              value: {
                sessionId: crypto.randomUUID(),
                patch: { id: "/diff.patch", mediaType: "text/x-diff", byteLength: 23, revision: 1 },
                source,
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
      config={{ payload: {
        capabilityToken: "0123456789abcdef",
        sessionSource: { kind: "branch", repoRoot: "/tmp/repo" },
        sourceOptions: [
          { label: "Branch", selected: true, sessionSource: { kind: "branch", repoRoot: "/tmp/repo" }, value: "branch" },
          { label: "Unstaged", selected: false, sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" }, value: "unstaged" },
        ],
        repoOptions: [
          { label: "repo", selected: true, sessionSource: { kind: "branch", repoRoot: "/tmp/repo" }, value: "/tmp/repo" },
          { label: "other-repo", selected: false, sessionSource: { kind: "branch", repoRoot: "/tmp/other-repo" }, value: "/tmp/other-repo" },
        ],
        transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
      } }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true })}
    />,
  );

  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 1);
  await waitFor(() => dom?.window.document.querySelector(".base-picker-button")?.textContent?.includes("chosen-base") === true);
  const sourceSelect = dom.window.document.getElementById("source-select") as HTMLSelectElement;
  sourceSelect.value = "unstaged";
  sourceSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 2);
  sourceSelect.value = "branch";
  sourceSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 3);
  expect(requests.filter((request) => request.method === "sessionOpen")[2].params.source)
    .toEqual({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "chosen-base" });

  const repoSelect = dom.window.document.getElementById("repo-select") as HTMLSelectElement;
  repoSelect.value = "/tmp/other-repo";
  repoSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 4);
  await waitFor(() => dom?.window.document.querySelector(".base-picker-button")?.textContent?.includes("other-base") === true);
  repoSelect.value = "/tmp/repo";
  repoSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 5);
  expect(requests.filter((request) => request.method === "sessionOpen")[4].params.source)
    .toEqual({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "chosen-base" });
});

test("pagehide cancels a typed session while its initial open is pending", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/unstaged.html");
  const requests: any[] = [];
  installDomGlobals(dom, () => new Response("", { status: 200 }));
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiff: {
        async postMessage(request: any) {
          requests.push(request);
          if (request.method === "sessionClose") {
            return { id: request.id, version: 1, result: { type: "sessionClosed" }, error: null };
          }
          await new Promise<void>(() => {});
        },
      },
    },
  };
  renderApp(
    <App
      config={{ payload: {
        capabilityToken: "0123456789abcdef",
        sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" },
        transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
      } }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true })}
    />,
  );
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 1);
  dom.window.dispatchEvent(new dom.window.Event("pagehide"));
  await waitFor(() => requests.filter((request) => request.method === "sessionClose").length === 1);
  expect(requests.find((request) => request.method === "sessionClose").params.sessionId)
    .toBe("00000000-0000-0000-0000-000000000000");
});

test("Last Turn reveals repo selection after switching to a typed git source", async () => {
  dom = createDom("cmux-diff-viewer://0123456789abcdef/last-turn.html");
  const requests: any[] = [];
  installDomGlobals(dom, () => new Response("", { status: 200 }));
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
                patch: { id: "/session.patch", mediaType: "text/x-diff", byteLength: 1, revision: 1 },
                source: request.params.source,
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
      config={{ payload: {
        capabilityToken: "0123456789abcdef",
        sessionSource: { kind: "patch", path: "/last-turn.patch" },
        sourceOptions: [
          { label: "Last turn", selected: true, sessionSource: { kind: "patch", path: "/last-turn.patch" }, value: "last-turn" },
          { label: "Unstaged", selected: false, sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" }, value: "unstaged" },
        ],
        repoOptions: [
          { label: "repo", selected: true, sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" }, value: "/tmp/repo" },
          { label: "other", selected: false, sessionSource: { kind: "unstaged", repoRoot: "/tmp/other" }, value: "/tmp/other" },
        ],
        transport: { kind: "webKit", endpoint: "cmuxDiff", protocolVersion: 1 },
      } }}
      initialStatus={createDiffViewerStatus("Loading diff", { loading: true })}
    />,
  );
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 1);
  expect(dom.window.document.getElementById("repo-select")).toBeNull();

  const sourceSelect = dom.window.document.getElementById("source-select") as HTMLSelectElement;
  sourceSelect.value = "unstaged";
  sourceSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 2);
  const repoSelect = dom.window.document.getElementById("repo-select") as HTMLSelectElement;
  expect(repoSelect).toBeTruthy();
  repoSelect.value = "/tmp/other";
  repoSelect.dispatchEvent(new dom.window.Event("change", { bubbles: true }));
  await waitFor(() => requests.filter((request) => request.method === "sessionOpen").length === 3);
  expect(requests.filter((request) => request.method === "sessionOpen")[2].params.source)
    .toEqual({ kind: "unstaged", repoRoot: "/tmp/other" });
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

test("adjacent diff file navigation moves in order and stops at the edges", () => {
  const items = [{ id: "one" }, { id: "two" }, { id: "three" }] as any;

  expect(adjacentItemId("one", items, 1)).toBe("two");
  expect(adjacentItemId("two", items, -1)).toBe("one");
  expect(adjacentItemId("three", items, 1)).toBe("");
  expect(adjacentItemId("one", items, -1)).toBe("");
  expect(adjacentItemId("missing", items, 1)).toBe("one");
  expect(adjacentItemId("missing", items, -1)).toBe("three");
  expect(adjacentItemId("missing", [], 1)).toBe("");
});

test("visible diff file follows the scroll position", () => {
  const items = [{ id: "one" }, { id: "two" }, { id: "three" }] as any;
  const tops: Record<string, number> = { one: 0, two: 500, three: 900 };

  expect(visibleItemId(items, 0, (id) => tops[id])).toBe("one");
  expect(visibleItemId(items, 650, (id) => tops[id])).toBe("two");
  expect(visibleItemId(items, 1000, (id) => tops[id])).toBe("three");

  const manyItems = Array.from({ length: 4096 }, (_, index) => ({ id: `item-${index}` })) as any;
  let lookups = 0;
  expect(visibleItemId(manyItems, 3000, (id) => {
    lookups += 1;
    return Number(id.slice("item-".length)) * 10;
  })).toBe("item-300");
  expect(lookups).toBeLessThanOrEqual(13);
});

test("native viewer navigation remains installed after an unrelated render", async () => {
  dom = createDom();
  installDomGlobals(dom, () => {
    throw new Error("unexpected fetch");
  });
  renderApp(
    <App
      config={{
        payload: { statusMessage: "Rendered diff" },
      }}
      initialStatus={createDiffViewerStatus("Rendered diff", { loading: false, statusOnly: true })}
    />,
  );

  const action = dom.window.__cmuxPerformDiffViewerNavigationAction;
  expect(action).toBeFunction();
  dom.window.document.getElementById("layout-toggle")?.click();
  await waitFor(() => dom?.window.document.documentElement.dataset.layout === "split");
  expect(dom.window.__cmuxPerformDiffViewerNavigationAction).toBe(action);
  expect(action?.("diffViewerOpenFileSearch")).toBe(true);
  expect(action?.("unknown")).toBe(false);
  await waitFor(() => dom?.window.document.getElementById("file-search-toggle")?.getAttribute("aria-pressed") === "true");
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
