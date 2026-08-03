import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createCodeMountNotifier, mountCodeSurface } from "./codeSurface";

describe("code surface mount", () => {
  test("starts the native sidecar once when the launcher mounts", () => {
    const messages: unknown[] = [];
    const notify = createCodeMountNotifier((message) => messages.push(message));
    notify();
    notify();
    notify();

    expect(messages).toEqual([{ type: "mount" }]);
  });

  test("paints the app shell before requesting the native mount", () => {
    const dom = new JSDOM("<!doctype html><html><head></head><body><main id=\"root\"></main></body></html>");
    const root = dom.window.document.getElementById("root");
    if (!(root instanceof dom.window.HTMLElement)) throw new Error("Missing test root");

    const previousDocument = globalThis.document;
    const previousWindow = globalThis.window;
    let shellWasPresentAtMount = false;
    Object.defineProperty(dom.window, "webkit", {
      configurable: true,
      value: {
        messageHandlers: {
          cmuxCode: {
            postMessage: () => {
              shellWasPresentAtMount = root.querySelector(".code-launcher__main") !== null;
            },
          },
        },
      },
    });

    try {
      Object.assign(globalThis, {
        document: dom.window.document,
        window: dom.window,
      });
      mountCodeSurface(root);

      expect(shellWasPresentAtMount).toBe(true);
      expect(root.querySelector(".code-launcher__sidebar")).not.toBeNull();
      expect(root.querySelector(".code-launcher__spinner")).toBeNull();
      expect(root.querySelector('[role="status"]')).toBeNull();
    } finally {
      Object.assign(globalThis, {
        document: previousDocument,
        window: previousWindow,
      });
      dom.window.close();
    }
  });

  test("inlines the classic launcher script for local WebKit pages", async () => {
    const htmlURL = new URL(
      "../../../Resources/markdown-viewer/webviews-app/code.html",
      import.meta.url,
    );
    const html = await Bun.file(htmlURL).text();

    expect(html).toContain("window.webkit?.messageHandlers?.cmuxCode?.postMessage");
    expect(html).not.toContain('src="./code-launcher.js"');
    expect(html).not.toContain('type="module"');
  });
});
