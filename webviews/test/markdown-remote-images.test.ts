// Remote images in the markdown page are private by default: the document gets no network URL
// until the reader clicks its placeholder. One click approves this document and refreshes every
// blocked image through the host's guarded same-origin resource URL.
import { afterEach, beforeAll, describe, expect, mock, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { MarkdownEditor as Editor, MarkdownEditorHost } from "../src/pages/markdown/editor";
import { resolveImageURL } from "../src/pages/markdown/host";
import { htmlPreview } from "../src/pages/markdown/htmlPreview";
import { MarkdownStore } from "../src/pages/markdown/store";
import type { PageClient } from "../src/pages/shared/pageClient";

let dom: JSDOM;
let MarkdownEditor: typeof Editor;
let remoteImagePlaceholder: (host: MarkdownEditorHost, source: string, alt: string) => HTMLElement;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  const scope = globalThis as Record<string, unknown>;
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "Element",
    "getComputedStyle",
    "MutationObserver",
    "DOMParser",
    "Text",
    "requestAnimationFrame",
    "KeyboardEvent",
    "MouseEvent",
    "Event",
  ])
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];
  const box = () => ({
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    width: 0,
    height: 0,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  });
  const rects = () => Object.assign([box()], { item: () => box() });
  for (const prototype of [dom.window.Range.prototype, dom.window.Element.prototype] as unknown as Array<
    Record<string, unknown>
  >) {
    prototype.getClientRects = rects;
    prototype.getBoundingClientRect = box;
  }
  ({ MarkdownEditor, markdownRemoteImagePlaceholder: remoteImagePlaceholder } =
    await import("../src/pages/markdown/editor"));
});

const editors: Editor[] = [];
afterEach(async () => {
  for (const editor of editors.splice(0)) await editor.destroy();
  document.body.replaceChildren();
});

describe("markdown remote images", () => {
  test("a remote source has no loadable URL before the host grants it", () => {
    expect(resolveImageURL("https://tracker.example/open.png", "/assets/")).toBe("");
  });

  test("one placeholder click loads every remote image through the granted document base", async () => {
    const listeners = new Set<() => void>();
    let remoteBase: string | undefined;
    const load = mock(async () => {
      remoteBase = "cmux-page://cmux.markdown/__image/document-token/";
      for (const listener of listeners) listener();
    });
    const host = {
      openLink: () => {},
      imageURL: (src: string) => resolveImageURL(src, "/assets/", remoteBase),
      label: (key: string) =>
        ({ remoteImageBlocked: "Remote image blocked", remoteImageLoad: "Load remote images" })[key] ?? key,
      loadRemoteImages: load,
      observeRemoteImages(listener: () => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    } as unknown as MarkdownEditorHost;
    host.htmlPreview = (html) => htmlPreview(html, host.imageURL, (src, alt) => remoteImagePlaceholder(host, src, alt));
    const root = document.createElement("div");
    document.body.append(root);
    const editor = new MarkdownEditor({ root, host });
    editors.push(editor);
    await editor.create();
    editor.load(
      "![first](https://tracker.example/one.png)\n\n![second](https://tracker.example/two.png)\n\n" +
        '<div>\n<img src="https://tracker.example/raw.png" alt="raw image">\n</div>\n',
    );

    expect(root.querySelectorAll(".md-image-node img")).toHaveLength(0);
    expect(root.querySelectorAll(".md-remote-image-placeholder")).toHaveLength(3);
    const button = root.querySelector<HTMLButtonElement>(".md-remote-image-placeholder button")!;
    expect(button.textContent).toBe("Load remote images");
    button.click();
    await Promise.resolve();
    await Promise.resolve();

    expect(load).toHaveBeenCalledTimes(1);
    expect(root.querySelectorAll(".md-remote-image-placeholder")).toHaveLength(0);
    const images = [...root.querySelectorAll<HTMLImageElement>(".md-image-node img")];
    expect(images).toHaveLength(2);
    expect(images.every((image) => image.src.startsWith("cmux-page://cmux.markdown/__image/document-token/"))).toBe(
      true,
    );
    expect(
      root
        .querySelector<HTMLImageElement>(".md-raw-preview img")
        ?.src.startsWith("cmux-page://cmux.markdown/__image/document-token/"),
    ).toBe(true);
  });

  test("a late approval cannot grant the document navigated to afterward", async () => {
    let finishApproval: ((value: { remoteImageBase: string }) => void) | undefined;
    let approvedPath: unknown;
    const file = (path: string) => ({ path, text: "# File\n", hash: path, assetBase: "/assets/" });
    const client = {
      async call<R>(op: string, params: unknown): Promise<R> {
        if (op === "cmux.markdown.config") return file("/a.md") as R;
        if (op === "cmux.markdown.open") return file((params as { path: string }).path) as R;
        if (op === "cmux.markdown.loadRemoteImages") {
          approvedPath = (params as { path: string }).path;
          return new Promise<{ remoteImageBase: string }>((resolve) => {
            finishApproval = resolve;
          }) as Promise<R>;
        }
        throw new Error(`unexpected ${op}`);
      },
      async subscribe() {
        return () => {};
      },
      handle() {
        return () => {};
      },
    } satisfies PageClient;
    const store = new MarkdownStore(client);
    await store.start();

    const approval = store.loadRemoteImages();
    await store.openFile("/b.md");
    finishApproval?.({ remoteImageBase: "/__image/a-token/" });
    await approval;

    expect(approvedPath).toBe("/a.md");
    expect(store.getState().config?.path).toBe("/b.md");
    expect(store.getState().config?.remoteImageBase).toBeUndefined();
  });
});
