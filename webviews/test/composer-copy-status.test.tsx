import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { ComposerBox } from "../src/agent-session/acpmux/ComposerBox";
import { inlineToken, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { setNativeHost } from "../src/agent-session/acpmux/native";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  setNativeHost(undefined);
  dom.window.localStorage.clear();
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

async function openBox(size: number, shell = false) {
  const ready = deferred<void>();
  let currentAttachments: ComposerAttachment[] = [];
  let addAttachment!: (attachment: ComposerAttachment) => void;
  const attachment: ComposerAttachment = {
    id: "file",
    kind: "text",
    name: "large.txt",
    mimeType: "text/plain",
    size,
    text: "x".repeat(size),
  };
  function Box() {
    const [value, setValue] = useState(shell ? "See attached file" : `See ${inlineToken(attachment.id)}`);
    const [attachments, setAttachments] = useState([attachment]);
    currentAttachments = attachments;
    addAttachment = (item) => setAttachments((current) => [...current, item]);
    return (
      <ComposerBox
        field={{ value, onChange: setValue, selectionKey: "clipboard-chat", onReady: () => ready.resolve() }}
        attachments={attachments}
        setAttachments={setAttachments}
        onRemoveAttachment={(id) => setAttachments((current) => current.filter((item) => item.id !== id))}
        fieldMenu={[]}
        chromeItems={[]}
        fieldOverlay={shell ? <span>Shell prompt</span> : undefined}
      />
    );
  }
  const { createRoot } = await import("react-dom/client");
  root = createRoot(host);
  act(() => root!.render(<Box />));
  await act(async () => {
    await ready.promise;
  });
  return {
    field: () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!,
    attachmentIds: () => currentAttachments.map((item) => item.id),
    addAttachment: (item: ComposerAttachment) => addAttachment(item),
  };
}

function copySelection(kind: "copy" | "cut" = "copy") {
  const field = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!;
  field.acpmuxMarkdownField!.selectAll();
  const copy = new dom.window.Event(kind, { bubbles: true, cancelable: true });
  Object.defineProperty(copy, "clipboardData", { value: { setData() {}, getData: () => "" } });
  host.querySelector(".ProseMirror")!.dispatchEvent(copy);
  expect(copy.defaultPrevented).toBe(true);
}

function stageHost(mode: "pause" | "fail-once" | "complete" | "incomplete") {
  let begins = 0;
  let bigChunks = 0;
  let failed = false;
  let committed = 0;
  const paused = deferred<void>();
  const held = deferred<void>();
  const cancelled = deferred<void>();
  const published = deferred<void>();
  const republished = deferred<void>();
  setNativeHost(async (method, params) => {
    if (method === "composer.copy.begin")
      return { token: `token-${++begins}`, batchToken: "batch", chunkSize: 512 * 1024 };
    if (method === "composer.copy.chunk") {
      const bytes = Buffer.from(String(params.data), "base64");
      const offset = Number(params.offset) + bytes.length;
      if (bytes.length > 32 * 1024) {
        bigChunks++;
        if (mode === "pause" && bigChunks === 2) {
          paused.resolve();
          await held.promise;
        }
        if (mode === "fail-once" && !failed) {
          failed = true;
          throw new Error("disk write failed");
        }
      }
      return { offset };
    }
    if (method === "composer.copy.finish") return { reference: params.token };
    if (method === "composer.copy.cancel") {
      cancelled.resolve();
      return {};
    }
    if (method === "composer.copy.staged" || method === "composer.copy") {
      committed++;
      published.resolve();
      if (committed > 1) republished.resolve();
      const items = params.items as { name: string }[];
      const files = items.map((item, index) => ({ item: index, name: item.name }));
      if (mode === "incomplete" && committed === 1) files.pop();
      return { copyID: "copy-id", files, skipped: items.length - files.length };
    }
    return {};
  });
  return { paused, held, cancelled, published, republished, commits: () => committed, begins: () => begins };
}

test("a 4 MiB copy shows acknowledged progress and Cancel without committing partial data", async () => {
  const native = stageHost("pause");
  await openBox(4 * 1024 * 1024);
  act(copySelection);
  await act(async () => {
    await native.paused.promise;
  });
  const status = host.querySelector(".acpmux-composer-copy-status")!;
  expect(status.textContent).toContain("Copying");
  const progress = status.querySelector("progress")!;
  expect(Number(progress.getAttribute("value"))).toBeGreaterThan(0);
  expect(Number(progress.getAttribute("value"))).toBeLessThan(100);
  expect(status.querySelector("button")!.textContent).toBe("Cancel");
  act(() => status.querySelector("button")!.click());
  expect(host.querySelector(".acpmux-composer-copy-status")).toBeNull();
  await act(async () => {
    native.held.resolve();
    await native.cancelled.promise;
  });
  expect(native.commits()).toBe(0);
});

test("a failed large copy offers Retry and finishes the original selection", async () => {
  const native = stageHost("fail-once");
  await openBox(4 * 1024 * 1024);
  act(copySelection);
  await act(async () => {
    await native.cancelled.promise;
  });
  expect(host.textContent).toContain("Couldn’t copy attachments");
  const retry = host.querySelector<HTMLButtonElement>(".acpmux-composer-copy-status button")!;
  expect(retry.textContent).toBe("Retry");
  expect(host.textContent).not.toContain("disk write failed");
  const begins = native.begins();
  act(() => retry.click());
  await act(async () => {
    await native.published.promise;
  });
  expect(host.querySelector(".acpmux-composer-copy-status")).toBeNull();
  expect(native.begins()).toBeGreaterThan(begins);
  expect(native.commits()).toBe(1);
});

test("leaving the composer cancels its in-flight copy", async () => {
  const native = stageHost("pause");
  await openBox(4 * 1024 * 1024);
  act(copySelection);
  await act(async () => {
    await native.paused.promise;
  });
  act(() => root!.unmount());
  root = undefined;
  await act(async () => {
    native.held.resolve();
    await native.cancelled.promise;
  });
  expect(native.commits()).toBe(0);
});

test("small copies keep their immediate path without a status line", async () => {
  const native = stageHost("complete");
  await openBox(8);
  act(copySelection);
  expect(host.querySelector(".acpmux-composer-copy-status")).toBeNull();
  expect(native.begins()).toBe(0);
  expect(native.commits()).toBe(1);
});

test("cancelling a 4 MiB Cut preserves its text and attachments", async () => {
  const native = stageHost("pause");
  const box = await openBox(4 * 1024 * 1024);
  const draft = box.field().value();
  act(() => copySelection("cut"));
  await act(async () => {
    await native.paused.promise;
  });
  expect(box.field().value()).toBe(draft);
  expect(box.attachmentIds()).toEqual(["file"]);
  act(() => host.querySelector<HTMLButtonElement>(".acpmux-composer-copy-status button")!.click());
  await act(async () => {
    native.held.resolve();
    await native.cancelled.promise;
  });
  expect(box.field().value()).toBe(draft);
  expect(box.attachmentIds()).toEqual(["file"]);
  expect(native.commits()).toBe(0);
});

test("a failed 4 MiB Cut keeps its draft until Retry commits the copy", async () => {
  const native = stageHost("fail-once");
  const box = await openBox(4 * 1024 * 1024);
  const draft = box.field().value();
  act(() => copySelection("cut"));
  await act(async () => {
    await native.cancelled.promise;
  });
  expect(box.field().value()).toBe(draft);
  expect(box.attachmentIds()).toEqual(["file"]);
  const retry = host.querySelector<HTMLButtonElement>(".acpmux-composer-copy-status button")!;
  expect(retry.textContent).toBe("Retry");
  act(() => retry.click());
  await act(async () => {
    await native.published.promise;
  });
  expect(box.field().value()).toBe("");
  expect(box.attachmentIds()).toEqual([]);
  expect(native.commits()).toBe(1);
});

test.each(["copy", "cut"] as const)("an incomplete 4 MiB %s warns and preserves its entire draft", async (kind) => {
  const native = stageHost("incomplete");
  const box = await openBox(4 * 1024 * 1024);
  act(() =>
    box.addAttachment({
      id: "missing",
      kind: "text",
      name: "deleted.txt",
      mimeType: "text/plain",
      size: 4,
      path: "/deleted.txt",
    }),
  );
  const draft = box.field().value();
  act(() => copySelection(kind));
  await act(async () => {
    await native.published.promise;
  });
  expect(native.commits()).toBe(1);
  expect(box.field().value()).toBe(draft);
  expect(box.attachmentIds()).toEqual(["file", "missing"]);
  const status = host.querySelector(".acpmux-composer-copy-status")!;
  expect(status.textContent).toContain("Some attachments couldn’t be copied.");
  expect(status.querySelector("button")!.textContent).toBe("Retry");
  act(() => status.querySelector<HTMLButtonElement>("button")!.click());
  await act(async () => {
    await native.republished.promise;
  });
  expect(native.commits()).toBe(2);
  expect(host.querySelector(".acpmux-composer-copy-status")).toBeNull();
  expect(box.field().value()).toBe(kind === "cut" ? "" : draft);
  expect(box.attachmentIds()).toEqual(kind === "cut" ? [] : ["file", "missing"]);
});

test("a small incomplete Copy clears its warning when Retry publishes every item", async () => {
  const native = stageHost("incomplete");
  const box = await openBox(8);
  act(() =>
    box.addAttachment({
      id: "missing",
      kind: "text",
      name: "deleted.txt",
      mimeType: "text/plain",
      size: 4,
      path: "/deleted.txt",
    }),
  );
  act(copySelection);
  await act(async () => {
    await native.published.promise;
  });
  const status = host.querySelector(".acpmux-composer-copy-status")!;
  expect(status.textContent).toContain("Some attachments couldn’t be copied.");
  act(() => status.querySelector<HTMLButtonElement>("button")!.click());
  await act(async () => {
    await native.republished.promise;
  });
  expect(native.commits()).toBe(2);
  expect(native.begins()).toBe(0);
  expect(host.querySelector(".acpmux-composer-copy-status")).toBeNull();
});

test("a 4 MiB Cut deletes its original selection after commit even if the caret moves", async () => {
  const native = stageHost("pause");
  const box = await openBox(4 * 1024 * 1024);
  const draft = box.field().value();
  act(() => copySelection("cut"));
  await act(async () => {
    await native.paused.promise;
  });
  expect(box.field().value()).toBe(draft);
  act(() => box.field().setCaret(0));
  await act(async () => {
    native.held.resolve();
    await native.published.promise;
  });
  expect(box.field().value()).toBe("");
  expect(box.attachmentIds()).toEqual([]);
  expect(native.commits()).toBe(1);
});

test("edits made while a 4 MiB Cut stages survive its successful copy", async () => {
  const native = stageHost("pause");
  const box = await openBox(4 * 1024 * 1024);
  act(() => copySelection("cut"));
  await act(async () => {
    await native.paused.promise;
  });
  act(() => {
    box.field().setCaret(0);
    box.field().insertText("Updated ");
  });
  const edited = box.field().value();
  expect(edited).toStartWith("Updated ");
  await act(async () => {
    native.held.resolve();
    await native.published.promise;
  });
  expect(box.field().value()).toBe(edited);
  expect(box.attachmentIds()).toEqual(["file"]);
  expect(native.commits()).toBe(1);
});

test("inline attachments added while a 4 MiB Cut stages preserve the changed draft", async () => {
  const native = stageHost("pause");
  const box = await openBox(4 * 1024 * 1024);
  const strip = (id: string): ComposerAttachment => ({
    id,
    kind: "text",
    name: `${id}.txt`,
    mimeType: "text/plain",
    size: 5,
    text: "hello",
  });
  act(() => box.addAttachment(strip("selected-strip")));
  act(() => copySelection("cut"));
  await act(async () => {
    await native.paused.promise;
  });
  act(() => {
    box.field().setCaret(Number.MAX_SAFE_INTEGER);
    box.addAttachment(strip("new-strip"));
  });
  const edited = box.field().value();
  expect(edited).toContain(inlineToken("new-strip"));
  await act(async () => {
    native.held.resolve();
    await native.published.promise;
  });
  expect(box.field().value()).toBe(edited);
  expect(box.attachmentIds().sort()).toEqual(["file", "new-strip", "selected-strip"]);
  expect(native.commits()).toBe(1);
});

test("a committed shell Cut preserves strip attachments added while its 4 MiB copy stages", async () => {
  const native = stageHost("pause");
  // Shell mode keeps its attachments in the strip: unlike a visual strip setting, it stops
  // inline.ready from inserting each newly attached file into the editor's document.
  const box = await openBox(4 * 1024 * 1024, true);
  const strip = (id: string): ComposerAttachment => ({
    id,
    kind: "text",
    name: `${id}.txt`,
    mimeType: "text/plain",
    size: 5,
    text: "hello",
  });
  act(() => box.addAttachment(strip("selected-strip")));
  const draft = box.field().value();
  act(() => copySelection("cut"));
  await act(async () => {
    await native.paused.promise;
  });
  act(() => box.addAttachment(strip("new-strip")));
  expect(box.field().value()).toBe(draft);
  await act(async () => {
    native.held.resolve();
    await native.published.promise;
  });
  expect(box.field().value()).toBe("");
  expect(box.attachmentIds()).toEqual(["new-strip"]);
  expect(native.commits()).toBe(1);
});
