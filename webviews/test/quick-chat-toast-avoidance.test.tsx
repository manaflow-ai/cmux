// The app's toasts never cover the Quick Chat's composer, and it never moves for them (Leo,
// 2026-11-07: "The composer should never ever rise up because there's some sort of ... tooltip type
// thing"). The panel is a bottom-aligned column, so its asks and composer rest at its foot, where
// toasts rest, with or without a thread: whenever the panel is mounted the page reports its bottom
// stack's box (`pane.toastAvoidance`: the asks and the composer, never the thread or the header) and
// the host lifts the toasts above it, as for the chat's bottom stack.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>");
  const { window } = dom;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  });
  const box = (left: number, top: number, right: number, bottom: number) =>
    ({ left, top, right, bottom, width: right - left, height: bottom - top, x: left, y: top }) as DOMRect;
  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    if (this.classList.contains("acpmux-composer")) return box(12, 380, 468, 470);
    if (this.classList.contains("acpmux-permission")) return box(8, 300, 472, 374);
    if (this.classList.contains("acpmux-quick-thread")) return box(0, 0, 480, 300);
    if (this.classList.contains("acpmux-floating-header")) return box(0, 0, 480, 42);
    return box(0, 0, 0, 0);
  };
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await teardownDom(saved, { scope });
});

/// A few macrotask turns: the composer's measure runs on the next frame (a 0 ms timer here).
const nextTurns = () =>
  act(async () => {
    for (let turn = 0; turn < 3; turn++) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  });

test("a mounted Quick Chat's asks and composer are what the app's toasts avoid, with or without a thread", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QuickSurface } = await import("../src/agent-session/acpmux/QuickSurface");
  const { setNativeHost } = await import("../src/agent-session/acpmux/native");
  const { resetToastAvoidanceReports } = await import("../src/agent-session/acpmux/toastAvoidance");
  resetToastAvoidanceReports();
  const reports: unknown[] = [];
  setNativeHost(async (method, params) => {
    if (method === "pane.toastAvoidance") reports.push(params.rects);
    return undefined;
  });
  const root: Root = createRoot(host);
  try {
    // A fresh panel, no transcript: the composer still rests at the panel's foot.
    await act(async () => root.render(<QuickSurface composer={<form className="acpmux-composer" />} />));
    await nextTurns();
    expect(reports.at(-1)).toEqual([{ left: 12, top: 380, right: 468, bottom: 470 }]);

    // Still no transcript, a trust ask above the composer: the toasts lift above both.
    await act(async () =>
      root.render(
        <QuickSurface
          asks={<div className="acpmux-permission">Trust this folder?</div>}
          composer={<form className="acpmux-composer" />}
        />,
      ),
    );
    await nextTurns();
    expect(reports.at(-1)).toEqual([{ left: 8, top: 300, right: 472, bottom: 470 }]);

    // The reply's thread above: the stack is still the ask and the composer, never the thread.
    await act(async () =>
      root.render(
        <QuickSurface
          transcript={<p>Uploads now retry server errors.</p>}
          asks={<div className="acpmux-permission">Trust this folder?</div>}
          composer={<form className="acpmux-composer" />}
        />,
      ),
    );
    await nextTurns();
    expect(reports.at(-1)).toEqual([{ left: 8, top: 300, right: 472, bottom: 470 }]);

    // The ask is answered: the toasts follow the composer back down.
    await act(async () =>
      root.render(
        <QuickSurface
          transcript={<p>Uploads now retry server errors.</p>}
          composer={<form className="acpmux-composer" />}
        />,
      ),
    );
    await nextTurns();
    expect(reports.at(-1)).toEqual([{ left: 12, top: 380, right: 468, bottom: 470 }]);

    // The panel goes: the toasts stop avoiding a stack that left.
    await act(async () => root.unmount());
    await nextTurns();
    expect(reports.at(-1)).toEqual([]);
  } finally {
    setNativeHost(undefined);
    resetToastAvoidanceReports();
  }
});
