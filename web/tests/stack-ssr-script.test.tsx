import { describe, expect, mock, test } from "bun:test";
import { fileURLToPath } from "node:url";
import { runInNewContext } from "node:vm";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

const insertedCallbacks: Array<() => ReactElement | null> = [];

// Next can invoke server-inserted HTML callbacks more than once while a
// request is streamed. Capture the callback so the guard can be exercised
// without starting a Next server.
mock.module("next/navigation", () => ({
  useServerInsertedHTML(callback: () => ReactElement | null) {
    insertedCallbacks.push(callback);
  },
}));

const ssrLayoutEffectPath = fileURLToPath(
  new URL(
    "../node_modules/@stackframe/stack/dist/esm/components/elements/ssr-layout-effect.js",
    import.meta.url,
  ),
);
const { SsrScript } = await import(ssrLayoutEffectPath);

describe("Stack SSR bootstrap script", () => {
  test("inserts one script when streaming invokes the callback twice", () => {
    insertedCallbacks.length = 0;
    const rendered = renderToStaticMarkup(
      createElement(SsrScript, {
        nonce: "test-nonce",
        script: "window.__cmuxTheme = true;",
      }),
    );

    expect(rendered).toBe("");
    expect(insertedCallbacks).toHaveLength(1);

    const callback = insertedCallbacks[0]!;
    const first = callback();
    const second = callback();

    const firstElement = first as ReactElement<{
      dangerouslySetInnerHTML: { __html: string };
    }>;
    const bodyReadyScript = firstElement.props.dangerouslySetInnerHTML.__html;
    expect(bodyReadyScript).toContain("if(!document.body)return false");
    expect(bodyReadyScript).toContain("MutationObserver");
    expect(renderToStaticMarkup(firstElement)).toContain(
      'nonce="test-nonce"',
    );
    expect(renderToStaticMarkup(firstElement)).toContain(
      "window.__cmuxTheme = true;",
    );

    const observerCallbacks: Array<() => void> = [];
    let observerDisconnected = false;
    const context = {
      document: {
        body: null as object | null,
        documentElement: {},
      },
      MutationObserver: class {
        constructor(private readonly callback: () => void) {
          observerCallbacks.push(callback);
        }

        observe() {}

        disconnect() {
          observerDisconnected = true;
        }
      },
      window: {} as Record<string, unknown>,
    };
    runInNewContext(bodyReadyScript, context);
    expect(observerCallbacks).toHaveLength(1);
    expect(context.window.__cmuxTheme).toBeUndefined();
    context.document.body = {};
    observerCallbacks[0]!();
    expect(context.window.__cmuxTheme).toBe(true);
    expect(observerDisconnected).toBe(true);
    expect(second).toBeNull();
  });
});
