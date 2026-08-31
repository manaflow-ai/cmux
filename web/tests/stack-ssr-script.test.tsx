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
    expect(bodyReadyScript).toContain("document.readyState===\"loading\"");
    expect(bodyReadyScript).toContain("DOMContentLoaded");
    expect(renderToStaticMarkup(firstElement)).toContain(
      'nonce="test-nonce"',
    );
    expect(renderToStaticMarkup(firstElement)).toContain(
      "window.__cmuxTheme = true;",
    );

    const domReadyCallbacks: Array<() => void> = [];
    const context = {
      document: {
        readyState: "loading",
        body: null as object | null,
        documentElement: {},
        addEventListener(_event: string, callback: () => void) {
          domReadyCallbacks.push(callback);
        },
      },
      window: {} as Record<string, unknown>,
    };
    runInNewContext(bodyReadyScript, context);
    expect(domReadyCallbacks).toHaveLength(1);
    expect(context.window.__cmuxTheme).toBeUndefined();
    context.document.body = {};
    context.document.readyState = "interactive";
    domReadyCallbacks[0]!();
    expect(context.window.__cmuxTheme).toBe(true);
    expect(second).toBeNull();
  });
});
