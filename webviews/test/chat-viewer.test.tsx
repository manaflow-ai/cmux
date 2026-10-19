// The chat's viewer (labs chatViewer, Lucas 2026-10-19): a path chip's click goes to the viewer the
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
  expect(host.textContent).toContain("second line");
  expect(host.querySelector(".acpmux-file-viewer-note")?.textContent).toContain("2000000");
  const [tab, editor] = [...host.querySelectorAll<HTMLButtonElement>(".acpmux-diff-tool")];
  await act(async () => tab!.click());
  await act(async () => editor!.click());
  expect(opened).toEqual([
    ["/Users/you/src/app/notes.txt", "tab"],
    ["/Users/you/src/app/notes.txt", "editor"],
  ]);
  // Only the X leaves (Lucas 2026-10-19: no Back to transcript chevron).
  expect(host.querySelector(".acpmux-diff-back")).toBeNull();
  await act(async () => host.querySelector<HTMLButtonElement>('button[aria-label="Close"]')!.click());
  expect(closed).toBe(1);
  const section = host.querySelector("section")!;
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

test("Changes shows its existing failed-open message when a changed file cannot be read", async () => {
  const { createRoot } = await import("react-dom/client");
  const { DiffPanel } = await import("../src/agent-session/acpmux/DiffPanel");
  const { useChatViewer } = await import("../src/agent-session/acpmux/useChatViewer");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const read = async () => undefined;
  setChipHost(async () => {
    throw new Error("pathInvalid");
  });
  function Changes() {
    const viewer = useChatViewer("A", "/chat", () => {}, read);
    return (
      <DiffPanel
        files={[
          {
            path: "/chat/note.txt",
            displayPath: "note.txt",
            edits: [{ toolId: "edit", numbered: false, hunks: [{ lines: [{ type: "add", text: "hello" }] }] }],
            additions: 1,
            deletions: 0,
            created: false,
          },
        ]}
        onClose={() => {}}
        onOpenFile={(path) => viewer.viewFile(path)}
      />
    );
  }
  try {
    root = createRoot(host);
    await act(async () => root!.render(<Changes />));
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    await act(async () => host.querySelector<HTMLButtonElement>('[aria-label="More actions for note.txt"]')!.click());
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
      (item) => item.textContent === "Open file in a tab",
    );
    expect(item !== undefined).toBe(true);
    await act(async () => item!.click());
    expect(host.querySelector(".acpmux-diff-notice-text")?.textContent).toBe("pathInvalid");
    expect(host.querySelector(".acpmux-diff-panel") !== null).toBe(true);
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

test("transcript Changes closes Thread details permanently through the shared opening path", async () => {
  const view = await viewerHarness();
  expect(host.querySelector("aside")?.textContent).toBe("Thread details");
  await view.click("changes");
  await act(async () => host.querySelector<HTMLButtonElement>("#diff button")!.click());
  expect(host.querySelector("#diff") === null).toBe(true);
  expect(host.querySelector("aside") === null).toBe(true);
});

for (const operation of ["file.list", "file.search"]) {
  test(`a ${operation} reply cannot update Files after a newer file open starts`, async () => {
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
      await act(async () =>
        old.resolve({ entries: [{ name: "stale.txt", kind: "file" }], results: [{ path: "stale.txt" }] }),
      );
      expect(host.querySelector(".acpmux-files-list")?.textContent ?? "").not.toContain("stale.txt");
      await act(async () => file.resolve(textReply("new")));
    } finally {
      setChipHost(undefined);
    }
  });
}
