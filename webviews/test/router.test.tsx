import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "@tanstack/react-router";
import { createWebviewsRouter } from "../src/router";

test("generated diff viewer file paths render the webview instead of TanStack not-found", async () => {
  await expectRouteToRenderWebview(
    "cmux-diff-viewer://01234567-89ab-cdef-0123-456789abcdef/diff-123-opening.html",
  );
});

test("generated diff viewer hash routes render the webview instead of TanStack not-found", async () => {
  await expectRouteToRenderWebview(
    "http://127.0.0.1:49308/fe60ff23-48f0-4d00-b066-85564f88c99e/diff-1780725374-17DB604C-unstaged.html#/cmux-diff-viewer",
  );
});

async function expectRouteToRenderWebview(url: string) {
  const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url,
  });
  const originalWindow = (globalThis as any).window;
  const originalDocument = (globalThis as any).document;
  const originalHistory = (globalThis as any).history;
  const originalScrollTo = (globalThis as any).scrollTo;
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    const scrollTo = () => {};
    (globalThis as any).window = dom.window;
    (globalThis as any).document = dom.window.document;
    (globalThis as any).history = dom.window.history;
    (globalThis as any).scrollTo = scrollTo;
    dom.window.scrollTo = scrollTo;
    const router = createWebviewsRouter(() => <main data-testid="webview">webview</main>);
    flushSync(() => {
      root.render(<RouterProvider router={router} />);
    });
    await router.load();

    expect(dom.window.document.querySelector("[data-testid='webview']")).toBeTruthy();
    expect(dom.window.document.body.textContent).not.toContain("Not Found");
  } finally {
    flushSync(() => root.unmount());
    await new Promise((resolve) => setTimeout(resolve, 0));
    dom.window.close();
    if (originalWindow === undefined) {
      delete (globalThis as any).window;
    } else {
      (globalThis as any).window = originalWindow;
    }
    if (originalDocument === undefined) {
      delete (globalThis as any).document;
    } else {
      (globalThis as any).document = originalDocument;
    }
    if (originalHistory === undefined) {
      delete (globalThis as any).history;
    } else {
      (globalThis as any).history = originalHistory;
    }
    if (originalScrollTo === undefined) {
      delete (globalThis as any).scrollTo;
    } else {
      (globalThis as any).scrollTo = originalScrollTo;
    }
  }
}
