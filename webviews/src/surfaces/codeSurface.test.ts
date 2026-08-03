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

  test("runs the bundled launcher from the local page", async () => {
    const htmlURL = new URL(
      "../../../Resources/markdown-viewer/webviews-app/code.html",
      import.meta.url,
    );
    const html = await Bun.file(htmlURL).text();
    const dom = new JSDOM(html, { url: htmlURL.href });
    const script = dom.window.document.querySelector("script")?.textContent;
    if (!script) throw new Error("Missing bundled launcher");

    const previousDocument = globalThis.document;
    const previousWindow = globalThis.window;
    let mountWasRequested = false;
    Object.defineProperty(dom.window, "webkit", {
      configurable: true,
      value: {
        messageHandlers: {
          cmuxCode: {
            postMessage: () => {
              mountWasRequested = true;
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
      Function(script)();

      expect(mountWasRequested).toBe(true);
      expect(dom.window.document.querySelector(".code-launcher__main")).not.toBeNull();
      expect(dom.window.document.querySelector('[role="status"]')).toBeNull();
    } finally {
      Object.assign(globalThis, {
        document: previousDocument,
        window: previousWindow,
      });
      dom.window.close();
    }
  });

  test("hides the upstream sidebar mark", async () => {
    const cssURL = new URL("../../code-sidecar/cmux-code.css", import.meta.url);
    const css = await Bun.file(cssURL).text();
    const dom = new JSDOM(
      `<!doctype html><html><head><style>${css}</style></head><body><a class="sidebar-brand"><svg></svg><span>Code</span></a></body></html>`,
      { pretendToBeVisual: true },
    );
    const mark = dom.window.document.querySelector(".sidebar-brand > svg");
    if (!(mark instanceof dom.window.SVGElement)) throw new Error("Missing test sidebar mark");

    expect(dom.window.getComputedStyle(mark).display).toBe("none");
    dom.window.close();
  });
});
