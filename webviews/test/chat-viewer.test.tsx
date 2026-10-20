// The chat's viewer (Lucas 2026-10-19): a path chip's click goes to the viewer the
// App registers instead of the app's tab over the chat, and the viewer shows the file with a way
// back and the app's own tab or editor one click away.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLStyleElement",
  "HTMLDivElement",
  "IntersectionObserver",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "sessionStorage",
  "location",
  "HTMLInputElement",
  "HTMLTextAreaElement",
  "customElements",
  "ShadowRoot",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "Event",
  "KeyboardEvent",
  "MouseEvent",
  "CustomEvent",
  "dispatchEvent",
  "addEventListener",
  "removeEventListener",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
    virtualConsole: new VirtualConsole(),
  });
  const { window } = dom;
  Object.assign(scope, {
    HTMLStyleElement: window.HTMLStyleElement,
    HTMLDivElement: window.HTMLDivElement,
    IntersectionObserver: class {
      constructor(private readonly report: (entries: { isIntersecting: boolean }[]) => void) {}
      observe() {
        queueMicrotask(() => this.report([{ isIntersecting: true }]));
      }
      unobserve() {}
      disconnect() {}
    },
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    sessionStorage: window.sessionStorage,
    location: window.location,
    HTMLInputElement: window.HTMLInputElement,
    HTMLTextAreaElement: window.HTMLTextAreaElement,
    customElements: window.customElements,
    ShadowRoot: window.ShadowRoot,
    CSSStyleSheet: window.CSSStyleSheet,
    DocumentFragment: window.DocumentFragment,
    SVGElement: window.SVGElement,
    HTMLTemplateElement: window.HTMLTemplateElement,
    Event: window.Event,
    KeyboardEvent: window.KeyboardEvent,
    MouseEvent: window.MouseEvent,
    CustomEvent: window.CustomEvent,
    dispatchEvent: window.dispatchEvent.bind(window),
    addEventListener: window.addEventListener.bind(window),
    removeEventListener: window.removeEventListener.bind(window),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a path chip opens in the registered viewer, else through the host", async () => {
  const { openPathChip, setChipHost, setPathViewer } = await import("../src/agent-session/acpmux/chips/host");
  const calls: [string, Record<string, unknown>][] = [];
  setChipHost(async (method, params) => {
    calls.push([method, params]);
    return null;
  });
  const viewed: string[] = [];
  setPathViewer((path) => {
    viewed.push(path);
  });
  openPathChip("src/App.tsx");
  expect(viewed).toEqual(["src/App.tsx"]);
  expect(calls).toEqual([]);
  setPathViewer(undefined);
  openPathChip("src/App.tsx");
  await Promise.resolve();
  await Promise.resolve();
  expect(calls).toEqual([["link.openPath", { path: "src/App.tsx" }]]);
  setChipHost(undefined);
});

test("the viewer shows the file, says when it is cut, and leaves only by an explicit choice", async () => {
  const { createRoot } = await import("react-dom/client");
  const { FileViewer } = await import("../src/agent-session/acpmux/FileViewer");
  const opened: [string, string][] = [];
  let closed = 0;
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <FileViewer
        file={{
          path: "/Users/you/src/app/notes.txt",
          text: "first line\nsecond line",
          bytes: 2_000_000,
          truncated: true,
        }}
        onClose={() => (closed += 1)}
        onOpenFile={(path, where) => opened.push([path, where])}
      />,
    ),
  );
  expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).toBe("notes.txt");
  const renderedCode = host.querySelector("diffs-container")?.shadowRoot?.textContent ?? host.textContent;
  expect(renderedCode).toContain("second line");
  expect(host.querySelector(".acpmux-file-viewer-note")?.textContent).toContain("2000000");
  const [tab, editor] = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-diff-tool")];
  await act(async () => tab!.click());
  await act(async () => editor!.click());
  expect(opened).toEqual([
    ["/Users/you/src/app/notes.txt", "tab"],
    ["/Users/you/src/app/notes.txt", "editor"],
  ]);
  await act(async () => tab!.focus());
  await act(async () => {
    tab!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
  });
  expect(document.activeElement === editor).toBe(true);
  editor!.addEventListener("keydown", (event) => event.preventDefault(), { once: true });
  await act(async () => {
    editor!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  });
  expect(closed).toBe(0);
  // Only the X leaves (Lucas 2026-10-19: no Back to transcript chevron).
  expect(host.querySelector(".acpmux-diff-back")).toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Close"]')!.click());
  expect(closed).toBe(1);
  const section = host.querySelector(".acpmux-file-viewer")!;
  await act(async () => {
    section.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(closed).toBe(2);
});

test("files highlight by extension or name, anything else is text", async () => {
  const { fileLanguage } = await import("../src/agent-session/acpmux/FileViewer");
  expect(fileLanguage("/a/App.tsx")).toBe("tsx");
  expect(fileLanguage("/a/main.rs")).toBe("rust");
  expect(fileLanguage("/a/Makefile")).toBe("make");
  expect(fileLanguage("/a/config.yml")).toBe("yml");
  expect(fileLanguage("/a/photo.heic")).toBe("text");
  expect(fileLanguage("/a/README")).toBe("text");
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

async function viewerHarness(reads?: (method: string, params: Record<string, unknown>) => Promise<unknown>) {
  const { createRoot } = await import("react-dom/client");
  const { useState } = await import("react");
  const { useChatViewer } = await import("../src/agent-session/acpmux/useChatViewer");
  const { FileViewer } = await import("../src/agent-session/acpmux/FileViewer");
  const { FilesView } = await import("../src/agent-session/acpmux/FilesView");
  let viewer!: ReturnType<typeof useChatViewer>;
  const read = reads ?? (async () => ({ entries: [{ name: "note.txt", kind: "file" }] }));
  function Harness({ session }: { session: string }) {
    const [changes, setChanges] = useState(false);
    const [details, setDetails] = useState(true);
    viewer = useChatViewer(
      session,
      "/chat",
      () => {
        setChanges(false);
        setDetails(false);
      },
      read,
    );
    return (
      <>
        <button id="files" onClick={(event) => viewer.openFiles("/chat", event.currentTarget)}>
          Files
        </button>
        <button id="link" onClick={(event) => void viewer.viewFile("/chat/note.txt", event.currentTarget)}>
          note.txt
        </button>
        <button id="changes" onClick={() => viewer.openChanges(() => setChanges(true))}>
          Changes
        </button>
        {details && <aside>Thread details</aside>}
        {changes && (
          <section id="diff">
            <button onClick={() => setChanges(false)}>Close changes</button>
          </section>
        )}
        {viewer.fileView && viewer.fileOpen && (
          <FileViewer file={viewer.fileView} onClose={viewer.closeFile} onOpenFile={() => {}} />
        )}
        {viewer.filesView && viewer.filesOpen && !viewer.fileView && (
          <FilesView
            root="/chat"
            folder={viewer.filesView.folder}
            source={viewer.filesSource}
            onFolder={(folder) => viewer.setFilesView((view) => view && { ...view, folder })}
            onOpen={viewer.viewFile}
            onClose={viewer.closeFiles}
          />
        )}
      </>
    );
  }
  root = createRoot(host);
  const render = (session: string) => act(async () => root!.render(<Harness session={session} />));
  await render("A");
  const click = (id: string) => act(async () => host.querySelector<HTMLButtonElement>(`#${id}`)!.click());
  return {
    render,
    click,
    get viewer() {
      return viewer;
    },
  };
}

const textReply = (text: string) => ({ kind: "text", path: `/chat/${text}.txt`, text });

test("a read from a previous session cannot open in the next session, even with the same folder", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const pending = deferred<unknown>();
  setChipHost(() => pending.promise);
  try {
    const view = await viewerHarness();
    await view.click("link");
    await view.render("B");
    await act(async () => pending.resolve(textReply("old")));
    expect(host.querySelector(".acpmux-file-viewer") === null).toBe(true);
  } finally {
    setChipHost(undefined);
  }
});

test("only the newest file read can replace the viewer", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const first = deferred<unknown>();
  const second = deferred<unknown>();
  let count = 0;
  setChipHost(() => (++count === 1 ? first.promise : second.promise));
  try {
    const view = await viewerHarness();
    await view.click("link");
    await view.click("link");
    await act(async () => second.resolve(textReply("new")));
    await act(async () => first.resolve(textReply("old")));
    expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).toBe("new.txt");
  } finally {
    setChipHost(undefined);
  }
});

for (const transition of ["close", "changes", "files"] as const) {
  test(`a read cannot reopen after ${transition}`, async () => {
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    const pending = deferred<unknown>();
    setChipHost(() => pending.promise);
    try {
      const view = await viewerHarness();
      await view.click("files");
      await view.click("link");
      if (transition === "close") await act(async () => view.viewer.closeFiles());
      else await view.click(transition);
      await act(async () => pending.resolve(textReply("old")));
      expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).not.toBe("old.txt");
      if (transition === "changes") expect(host.querySelector("#diff")).not.toBeNull();
    } finally {
      setChipHost(undefined);
    }
  });
}

for (const operation of ["file.list", "file.search"]) {
  test(`a ${operation} reply from a previous session cannot populate the next session's Files`, async () => {
    const old = deferred<unknown>();
    let calls = 0;
    const read = async (method: string) => (method === operation && ++calls === 1 ? old.promise : { entries: [] });
    const view = await viewerHarness(read);
    await view.click("files");
    if (operation === "file.search") {
      const input = host.querySelector<HTMLInputElement>("input")!;
      await act(async () => {
        Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, "old");
        input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
      });
    }
    await view.render("B");
    await view.click("files");
    await act(async () =>
      old.resolve({ entries: [{ name: "stale.txt", kind: "file" }], results: [{ path: "stale.txt" }] }),
    );
    expect(host.querySelector(".acpmux-files-list")?.textContent ?? "").not.toContain("stale.txt");
  });
}

test("a failed file read rejects and keeps the current file", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(async () => textReply("current"));
  try {
    const view = await viewerHarness();
    await view.click("link");
    setChipHost(async () => {
      throw new Error("pathInvalid");
    });
    let failed = false;
    await act(async () => {
      try {
        await view.viewer.viewFile("/chat/gone.txt");
      } catch {
        failed = true;
      }
    });
    expect(failed).toBe(true);
    expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).toBe("current.txt");
  } finally {
    setChipHost(undefined);
  }
});

test("Files shows its existing failure note when a listed file cannot be read", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(async () => {
    throw new Error("pathInvalid");
  });
  try {
    const view = await viewerHarness();
    await view.click("files");
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-files-row")!.click());
    expect(host.querySelector(".acpmux-files") !== null).toBe(true);
    expect(host.querySelector(".acpmux-file-viewer-note")?.textContent).toBe("Couldn't search files");
    expect(host.querySelector(".acpmux-files-list")?.textContent).toBe("note.txt");
  } finally {
    setChipHost(undefined);
  }
});

for (const kind of ["files", "link"] as const) {
  for (const dismissal of ["X", "Escape"] as const) {
    test(`${kind} returns focus to its opener after unmounting through ${dismissal}`, async () => {
      const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
      setChipHost(async () => textReply("note"));
      try {
        const view = await viewerHarness();
        await view.click(kind);
        expect(document.activeElement?.getAttribute("aria-label")).toBe("Close");
        await act(async () => {
          const close = host.querySelector<HTMLButtonElement>('button[aria-label="Close"]')!;
          if (dismissal === "X") close.click();
          else close.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
        });
        expect(host.querySelector(".acpmux-file-viewer") === null).toBe(true);
        expect(document.activeElement?.id).toBe(kind);
      } finally {
        setChipHost(undefined);
      }
    });
  }
}

test("transcript Changes preserves Thread details when the diff closes", async () => {
  const view = await viewerHarness();
  expect(host.querySelector("aside")?.textContent).toBe("Thread details");
  await view.click("changes");
  await act(async () => host.querySelector<HTMLButtonElement>("#diff button")!.click());
  expect(host.querySelector("#diff") === null).toBe(true);
  expect(host.querySelector("aside")?.textContent).toBe("Thread details");
});

for (const operation of ["file.list", "file.search"]) {
  test(`a ${operation} reply cannot update Files after a newer file opens`, async () => {
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    const old = deferred<unknown>();
    const file = deferred<unknown>();
    setChipHost(() => file.promise);
    const read = async (method: string) => (method === operation ? old.promise : { entries: [] });
    try {
      const view = await viewerHarness(read);
      await view.click("files");
      if (operation === "file.search") {
        const input = host.querySelector<HTMLInputElement>("input")!;
        await act(async () => {
          Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, "old");
          input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
        });
      }
      await view.click("link");
      await act(async () => file.resolve(textReply("new")));
      await act(async () =>
        old.resolve({ entries: [{ name: "stale.txt", kind: "file" }], results: [{ path: "stale.txt" }] }),
      );
      expect(host.querySelector(".acpmux-files-list")?.textContent ?? "").not.toContain("stale.txt");
    } finally {
      setChipHost(undefined);
    }
  });
}

for (const operation of ["file.list", "file.search"]) {
  for (const outcome of ["failed", "folder", "opened"]) {
    test(`a pending ${operation} still populates Files after a ${outcome} file read`, async () => {
      const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
      const pending = deferred<unknown>();
      setChipHost(async () => {
        if (outcome === "failed") throw new Error("pathInvalid");
        return { kind: outcome, path: "/chat/elsewhere" };
      });
      try {
        const view = await viewerHarness(async (method) => (method === operation ? pending.promise : { entries: [] }));
        await view.click("files");
        if (operation === "file.search") {
          const input = host.querySelector<HTMLInputElement>("input")!;
          await act(async () => {
            Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, "note");
            input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
          });
        }
        await act(async () => {
          try {
            await view.viewer.viewFile("/chat/elsewhere");
          } catch (error) {
            expect(outcome).toBe("failed");
            expect((error as Error).message).toBe("pathInvalid");
          }
        });
        await act(async () =>
          pending.resolve({
            entries: [{ name: "note.txt", kind: "file" }],
            results: [{ path: "note.txt" }],
          }),
        );
        expect(host.querySelector(".acpmux-files-list")?.textContent).toBe("note.txt");
        expect(view.viewer.filesOpen).toBe(true);
        expect(view.viewer.fileOpen).toBe(false);
      } finally {
        setChipHost(undefined);
      }
    });
  }
}

async function changesHarness(ran = true, failFileOpen = false, surface = "pane", remote = false) {
  const { createRoot } = await import("react-dom/client");
  const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");
  const { configureQuickActions } = await import("../src/agent-session/acpmux/header/quickActions");
  configureQuickActions({ quickActions: ["changes", "files"] });
  const calls: [string, Record<string, unknown>][] = [];
  window.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: async ({ method, params }: { method: string; params: Record<string, unknown> }) => {
          calls.push([method, params]);
          if (method === "file.open" && failFileOpen) return { ok: false, error: { userMessage: "pathInvalid" } };
          const value =
            method === "ready"
              ? { protocolVersion: 1, surface }
              : method === "pane.action"
                ? { ran }
                : method === "link.readPath"
                  ? { kind: "text", path: params.path, text: "note", bytes: 4, truncated: false }
                  : {};
          return { ok: true, value };
        },
      },
    },
  } as typeof window.webkit;
  root = createRoot(host);
  await act(async () => root!.render(<AcpmuxApp />));
  await act(async () =>
    window.cmuxAcpmuxBridge!.receive({
      type: "snapshot",
      protocolVersion: 1,
      sessionId: "A",
      summary: {
        sessionId: "A",
        cwd: "/chat",
        ...(remote ? { peer: "remote-host" } : {}),
        title: "Changes regression",
        harness: "claude",
        status: "idle",
      },
      rows: [
        { id: "prompt", kind: "user", text: "Edit note", version: 1, at: 1 },
        {
          id: "edit",
          kind: "activity",
          version: 1,
          at: 2,
          items: [
            {
              kind: "tool",
              text: "Edit note",
              tool: {
                id: "e1",
                title: "Edit note",
                status: "completed",
                kind: "edit",
                diffs: [{ path: "/chat/note.txt", oldText: "old", newText: "new" }],
              },
            },
          ],
        },
        { id: "end", kind: "turnSummary", status: "completed", version: 1, at: 3 },
      ],
      sessions: [],
      connection: "connected",
      isWorking: false,
      queue: [],
      catalog: [],
      canLoadOlder: false,
    }),
  );
  calls.length = 0;
  return calls;
}

test("header Changes runs the production action", async () => {
  const calls = await changesHarness();
  const changes = host.querySelector<HTMLButtonElement>('.acpmux-header-tools button[aria-label="Changes"]');
  expect(changes).not.toBeNull();
  await act(async () => changes!.click());
  expect(calls.filter(([method]) => method === "pane.action")).toEqual([
    ["pane.action", { id: "openDiffViewer", cwd: "/chat", mode: "toggle" }],
  ]);
  expect(host.querySelector(".acpmux-diff-panel")).toBeNull();
  expect(changes!.getAttribute("aria-pressed")).toBe("false");
});

test("transcript View changes opens the production diff", async () => {
  const calls = await changesHarness();
  const changes = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === "View changes",
  );
  expect(changes).toBeDefined();
  await act(async () => changes!.click());
  expect(calls.filter(([method]) => method === "pane.action")).toEqual([
    ["pane.action", { id: "openDiffViewer", cwd: "/chat", mode: "open" }],
  ]);
  expect(host.querySelector(".acpmux-diff-panel")).toBeNull();
});

test("unsupported host falls back to the turn diff and opens files in a tab", async () => {
  const calls = await changesHarness(false);
  const changes = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === "View changes",
  )!;
  await act(async () => changes.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(host.querySelector(".acpmux-diff-panel")).not.toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="More actions for note.txt"]')!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Open file in a tab",
  );
  expect(item).toBeDefined();
  await act(async () => item!.click());
  expect(calls.filter(([method]) => method === "file.open")).toEqual([
    ["file.open", { path: "/chat/note.txt", where: "tab" }],
  ]);
  expect(host.querySelector(".acpmux-file-viewer")).toBeNull();
});

test("Changes shows its existing failed-open message when the host cannot open a changed file", async () => {
  const calls = await changesHarness(false, true);
  const changes = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (button) => button.textContent === "View changes",
  )!;
  await act(async () => changes.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="More actions for note.txt"]')!.click());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === "Open file in a tab",
  )!;
  await act(async () => item.click());
  expect(calls.filter(([method]) => method === "file.open")).toEqual([
    ["file.open", { path: "/chat/note.txt", where: "tab" }],
  ]);
  expect(host.querySelector(".acpmux-diff-notice-text")?.textContent).toBe("pathInvalid");
  expect(host.querySelector(".acpmux-diff-panel")).not.toBeNull();
});

test("Quick Chat path links open through the host", async () => {
  const calls = await changesHarness(true, false, "quick");
  const { openPathChip } = await import("../src/agent-session/acpmux/chips/host");
  expect(host.querySelector('[data-surface="quick"]')).not.toBeNull();
  await act(async () => openPathChip("/chat/note.txt"));
  expect(calls.filter(([method]) => method === "link.openPath" || method === "link.readPath")).toEqual([
    ["link.openPath", { path: "/chat/note.txt" }],
  ]);
  expect(host.querySelector(".acpmux-file-viewer")).toBeNull();
});

test("a fresh layout shows the editable thread title and Thread details with a native tab row", async () => {
  const { setTabRow } = await import("../src/agent-session/acpmux/header/tabRow");
  const calls = await changesHarness();
  try {
    await act(async () => window.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
    expect(host.querySelector(".acpmux-thread-title__project")?.textContent).toBe("chat");
    expect(host.querySelector(".acpmux-summary-button")?.getAttribute("aria-label")).toBe("Thread details");
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-summary-button")!.click());
    expect(host.querySelector(".acpmux-summary-card")?.getAttribute("aria-label")).toBe("Thread details");
    expect(host.querySelector(".acpmux-thread-details")).not.toBeNull();
    await act(async () => setTabRow({ height: 32, trailingInset: 30 }));
    expect(host.querySelector(".acpmux-header[data-tab-row]")).toBeNull();
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-thread-title__name")!.click());
    const field = host.querySelector<HTMLInputElement>(".acpmux-thread-title__field")!;
    expect(field).not.toBeNull();
    field.value = "Renamed thread";
    await act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
    expect(calls.filter(([method]) => method === "pane.rename")).toEqual([["pane.rename", { name: "Renamed thread" }]]);
  } finally {
    await act(async () => {
      setTabRow(undefined);
    });
  }
});

test("switching threads resets the title draft and pending optimistic name", async () => {
  const calls = await changesHarness();
  const switchThread = async (sessionId: string) => {
    await act(async () =>
      window.cmuxAcpmuxBridge!.receive({
        type: "snapshot",
        protocolVersion: 1,
        sessionId,
        summary: { sessionId, cwd: "/chat", title: "Changes regression", harness: "claude", status: "idle" },
        rows: [{ id: "reply", kind: "assistant", text: "Ready", version: 1, at: 1 }],
        sessions: [],
        connection: "connected",
        isWorking: false,
        queue: [],
        catalog: [],
        canLoadOlder: false,
      }),
    );
  };
  const edit = async (name: string, commit: boolean) => {
    await act(async () => host.querySelector<HTMLButtonElement>(".acpmux-thread-title__name")!.click());
    const field = host.querySelector<HTMLInputElement>(".acpmux-thread-title__field")!;
    field.value = name;
    if (commit)
      await act(async () => field.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true })));
    return field;
  };
  await edit("Only A", true);
  expect(host.querySelector(".acpmux-thread-title__name")?.textContent).toBe("Only A");
  await switchThread("B");
  expect(host.querySelector(".acpmux-thread-title__name")?.textContent).toBe("Changes regression");
  const draft = await edit("B draft", false);
  await switchThread("C");
  expect(host.querySelector(".acpmux-thread-title__field")).toBeNull();
  expect(host.querySelector(".acpmux-thread-title__name")?.textContent).toBe("Changes regression");
  expect(draft.isConnected).toBe(false);
  expect(calls.filter(([method]) => method === "pane.rename")).toEqual([["pane.rename", { name: "Only A" }]]);
});

test("a fresh layout opens Files and linked files inside the chat without labs", async () => {
  const calls = await changesHarness();
  await act(async () => window.cmuxAcpmuxBridge!.applyCustomization({ layout: {} }));
  await act(async () =>
    host.querySelector<HTMLButtonElement>('.acpmux-header button[aria-label="Chat actions"]')!.click(),
  );
  const files = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.includes("Files"),
  );
  expect(files).toBeDefined();
  await act(async () => files!.click());
  expect(host.querySelector(".acpmux-files")).not.toBeNull();
  expect(calls.some(([method]) => method === "file.list")).toBe(true);
  expect(calls.some(([method]) => method === "pane.action")).toBe(false);
  const { openPathChip } = await import("../src/agent-session/acpmux/chips/host");
  await act(async () => openPathChip("/chat/note.txt"));
  expect(calls.filter(([method]) => method === "link.readPath")).toEqual([
    ["link.readPath", { path: "/chat/note.txt" }],
  ]);
  expect(host.querySelector(".acpmux-file-viewer-name")?.textContent).toBe("note.txt");
  expect(calls.some(([method]) => method === "link.openPath")).toBe(false);
});

test("remote chat without local Files opens path links through the host", async () => {
  const calls = await changesHarness(true, false, "pane", true);
  const { openPathChip } = await import("../src/agent-session/acpmux/chips/host");
  await act(async () => openPathChip("/chat/note.txt"));
  expect(calls.filter(([method]) => method === "link.openPath" || method === "link.readPath")).toEqual([
    ["link.openPath", { path: "/chat/note.txt" }],
  ]);
  expect(host.querySelector(".acpmux-file-viewer")).toBeNull();
});
