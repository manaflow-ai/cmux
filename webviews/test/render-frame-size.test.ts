// l10n-allow-file: fixture text and geometry, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { renderBridgeScript } from "../src/agent-session/acpmux/conversation/renderFrameShell";

test.each([false, true])("direct body text grows and shrinks with a viewport-sized body, mixed=%s", (mixed) => {
  const dom = new JSDOM(
    renderBridgeScript("light", "") + "<body>Long text" + (mixed ? "<p>After</p>" : "") + "</body>",
    {
      runScripts: "outside-only",
    },
  );
  try {
    const win = dom.window;
    const messages: { type: string; height: number }[] = [];
    const observers: (() => void)[] = [];
    let textHeight = 720;
    win.document.body.style.cssText = "height:100vh;margin:4px 0;padding:6px 0";
    Object.defineProperty(win, "innerHeight", { value: 1600 });
    Object.defineProperty(win.document.body, "scrollHeight", { value: 1600 });
    win.document.body.getBoundingClientRect = () => ({ top: 4, bottom: 1604, height: 1600 }) as DOMRect;
    const text = win.document.body.firstChild!;
    // JSDOM has no layout. Supply line geometry to the real bridge's measurement.
    win.document.createRange = () => {
      let selected: Node;
      return {
        selectNodeContents: (node: Node) => {
          selected = node;
        },
        getBoundingClientRect: () => {
          expect(selected).toBe(text);
          return { top: 10, bottom: 10 + textHeight, height: textHeight } as DOMRect;
        },
      } as Range;
    };
    const paragraph = win.document.querySelector("p");
    if (paragraph)
      paragraph.getBoundingClientRect = () =>
        ({ top: 10 + textHeight, bottom: 40 + textHeight, height: 30 }) as DOMRect;
    win.requestAnimationFrame = (callback) => {
      callback(0);
      return 1;
    };
    win.ResizeObserver = class {
      constructor(callback: () => void) {
        observers.push(callback);
      }
      observe() {}
      unobserve() {}
      disconnect() {}
    };
    win.MutationObserver = win.ResizeObserver;
    win.postMessage = (data: { type: string; height: number }) => {
      messages.push(data);
    };
    win.eval(win.document.querySelector("script")!.textContent!);
    win.dispatchEvent(new win.Event("DOMContentLoaded"));
    const measured = () => messages.filter((message) => message.type === "cmux-render-content-size").at(-1)?.height;
    expect(measured()).toBe(740 + (mixed ? 30 : 0));
    textHeight = 960;
    text.textContent += " More lines";
    observers.forEach((callback) => callback());
    expect(measured()).toBe(980 + (mixed ? 30 : 0));
    expect(win.__cmuxRenderContentHeight).toBe(measured());
    textHeight = 24;
    text.textContent = "Short";
    observers.forEach((callback) => callback());
    expect(measured()).toBe(44 + (mixed ? 30 : 0));
  } finally {
    dom.window.close();
  }
});
